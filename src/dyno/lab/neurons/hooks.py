"""Where in a layer the Lab reads (and changes) activations.

`block_output` is the residual stream after the layer, as before. The MLP sites have a neuron basis:

- `mlp_hidden`: the input to `down_proj`, `act(gate_proj(x)) * up_proj(x)`. One coordinate is one neuron.
- `mlp_gate_pre`: `gate_proj(x)` before the activation function. With `mlp_up`, it shows a SwiGLU neuron's sign regime
  (a negative value can come from either factor).
- `mlp_up`: `up_proj(x)`.
- `mlp_output`: the MLP's output, `down_proj(mlp_hidden)`.
- `attn_output`: the attention sublayer's output.

A hook wraps the module; the model is not otherwise changed. Gated MLPs (Llama, Qwen2/3, Mistral, Gemma 2/3) are
supported; others raise a clear error. `check()` proves on a real prompt that the wrapped MLP computes the same output
as the original, so a wrong activation function can't go unnoticed.
"""
from __future__ import annotations

HOOKS = ('block_output', 'mlp_hidden', 'mlp_gate_pre', 'mlp_up', 'mlp_output', 'attn_output')
MLP_HOOKS = ('mlp_hidden', 'mlp_gate_pre', 'mlp_up', 'mlp_output')
# Model types whose gated MLP uses tanh-approximated GELU instead of SiLU.
GELU = ('gemma', 'gemma2', 'gemma3', 'gemma3_text', 'gemma3n')


def layers_of(model):
    for path in ('layers', 'model.layers', 'language_model.model.layers', 'language_model.layers'):
        target = model
        try:
            for part in path.split('.'): target = getattr(target, part)
            return target, path
        except AttributeError:
            continue
    raise ValueError('This model does not expose its decoder layers')


def model_type(model, config=None):
    for source in (config or {}, getattr(model, 'args', None)):
        value = source.get('model_type') if isinstance(source, dict) else getattr(source, 'model_type', None)
        if value: return str(value)
    return str(getattr(model, 'model_type', 'unknown'))


def adapter(model, config=None):
    """(name, activation) for this model's gated MLP."""
    kind = model_type(model, config)
    text = (config or {}).get('text_config') or {}
    kind = text.get('model_type', kind) if isinstance(text, dict) else kind
    return kind, ('gelu_approx' if kind in GELU or kind.startswith('gemma') else 'silu')


def _mlp(layer):
    mlp = getattr(layer, 'mlp', None) or getattr(layer, 'feed_forward', None)
    if mlp is None or not all(hasattr(mlp, n) for n in ('gate_proj', 'up_proj', 'down_proj')):
        raise ValueError('This hook needs a gated MLP with gate_proj, up_proj and down_proj (Llama, Qwen, Mistral, Gemma). '
                         'Mixture-of-experts and other MLPs are not supported yet.')
    return mlp


def width(model, hook, layer=0):
    """The size of one position's activation at a hook."""
    layer_module = layers_of(model)[0][layer]
    if hook in ('mlp_hidden', 'mlp_gate_pre', 'mlp_up'):
        mlp = _mlp(getattr(layer_module, 'original', layer_module))
        mlp = getattr(mlp, 'original', mlp)
        # Quantized weights pack several values per 32-bit element.
        down = mlp.down_proj
        return int(down.weight.shape[1] * (32 // getattr(down, 'bits', 32)))
    return None


PROBE = {'on': False, 'inputs': {}}


def install(model, layers, hook, captured, active, collecting, config=None):
    """Wrap the given layers' hook sites. captured[i] receives [batch, token, width]; active[i](value) may replace it.

    Returns provenance: hook, adapter and module path."""
    import mlx.core as mx
    import mlx.nn as nn
    if hook not in HOOKS: raise ValueError(f'hook must be one of {", ".join(HOOKS)}')
    decoder, path = layers_of(model)
    if any(i >= len(decoder) for i in layers): raise ValueError(f'Model has {len(decoder)} layers; requested {layers}')
    name, activation = adapter(model, config)
    act = nn.gelu_approx if activation == 'gelu_approx' else nn.silu

    def record(index, value):
        if not isinstance(value, mx.array) or value.ndim != 3:
            raise ValueError(f'This model does not expose a supported [batch, token, width] value at {hook}')
        if index in active: value = active[index](value)
        if collecting[0]: captured[index] = value
        return value

    class Passthrough(nn.Module):
        """Keeps the wrapped module's interface (hybrid decoders consult attributes such as is_linear)."""
        def __init__(self, original, index):
            super().__init__()
            self.original = original
            object.__setattr__(self, '_index', index)

        def __getattr__(self, attr):
            try:
                return super().__getattr__(attr)
            except AttributeError:
                return getattr(super().__getattr__('original'), attr)

    class BlockTap(Passthrough):
        def __call__(self, *args, **kwargs):
            return record(self._index, self.original(*args, **kwargs))

    class AttentionTap(Passthrough):
        def __call__(self, *args, **kwargs):
            value = self.original(*args, **kwargs)
            if isinstance(value, tuple):  # some attentions return (output, cache)
                return (record(self._index, value[0]), *value[1:])
            return record(self._index, value)

    class MLPTap(Passthrough):
        def __call__(self, x):
            if PROBE['on']: PROBE['inputs'][self._index] = x
            m = self.original
            gate, up = m.gate_proj(x), m.up_proj(x)
            if hook == 'mlp_gate_pre': gate = record(self._index, gate)
            if hook == 'mlp_up': up = record(self._index, up)
            hidden = act(gate) * up
            if hook == 'mlp_hidden': hidden = record(self._index, hidden)
            out = m.down_proj(hidden)
            if hook == 'mlp_output': out = record(self._index, out)
            return out

    module_path = None
    for index in layers:
        layer = decoder[index]
        if hook == 'block_output':
            decoder[index] = BlockTap(layer, index); module_path = f'{path}[i]'
        elif hook == 'attn_output':
            attr = 'self_attn' if hasattr(layer, 'self_attn') else 'attention' if hasattr(layer, 'attention') else None
            if attr is None: raise ValueError('This model has no self_attn module to hook')
            setattr(layer, attr, AttentionTap(getattr(layer, attr), index)); module_path = f'{path}[i].{attr}'
        else:
            mlp = _mlp(layer)
            attr = 'mlp' if getattr(layer, 'mlp', None) is mlp else 'feed_forward'
            setattr(layer, attr, MLPTap(mlp, index)); module_path = f'{path}[i].{attr}'
    return dict(hook=hook, adapter=name, activation=activation if hook in MLP_HOOKS else None, module_path=module_path)


def check(model, tokenizer, layers, hook, text='The quick brown fox jumps over the lazy dog. In 1969, 2 + 2 = 4.'):
    """For MLP hooks: on a real prompt, the wrapped MLP must reproduce the original MLP's output from the same input
    (down_proj of the captured hidden state is the MLP output). Returns the worst relative error; raises above 1%."""
    if hook not in MLP_HOOKS: return None
    import mlx.core as mx
    decoder, _ = layers_of(model)
    PROBE.update(on=True, inputs={})
    try:
        model(mx.array([tokenizer.encode(text)]))
    finally:
        PROBE['on'] = False
    worst = 0.0
    for index in layers:
        tap = getattr(decoder[index], 'mlp', None) or getattr(decoder[index], 'feed_forward')
        x = PROBE['inputs'].get(index)
        if x is None: raise ValueError(f'Layer {index} did not run its MLP on the check prompt')
        expected, got = tap.original(x).astype(mx.float32), tap(x).astype(mx.float32)
        scale = float(mx.max(mx.abs(expected)).item()) or 1.0
        worst = max(worst, float(mx.max(mx.abs(expected - got)).item()) / scale)
    PROBE['inputs'] = {}
    if worst > 1e-2:
        raise ValueError(f'The {hook} hook does not reproduce the MLP output (relative error {worst:.3g}); this architecture is not supported')
    return worst
