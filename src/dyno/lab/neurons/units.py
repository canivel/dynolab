"""Which units drive an answer, what happens without them, and what turning one up does.

- `attribute`: for a prompt and a target token, rank units at a hook across layers by activation x gradient of the
  target's log-probability, summed over positions. Signed: a unit pushing against the answer ranks as strongly as one
  pushing for it, so either pole can matter.
- `ablate_set`: zero a list of (layer, unit) at every position; report P(target) and the top answers before and after,
  against random sets with the same number of units from the same layers (several seeds, with an interval).
- `steer`: add to one unit at every position (a multiple of its maximum, or an absolute value) while generating, and
  show the text at each strength.

The essay's Santa example is this loop: removing 8 negative-pole neurons dropped P(Santa) to 6%; removing the 20
neurons labeled Christmas or Santa only to 76%.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

MODES = ('attribute', 'ablate_set', 'steer')


def validate(config):
    c = dict(hook='mlp_hidden', layers='all', top=40, control_seeds=10, max_tokens=48)
    c.update({k: v for k, v in config.items() if v is not None})
    if c.get('mode') not in MODES: raise ValueError(f'mode must be one of {", ".join(MODES)}')
    prompts = c.get('prompts') or ([c['prompt']] if c.get('prompt') else [])
    if not prompts or not all(isinstance(p, str) and p.strip() for p in prompts) or len(prompts) > 32: raise ValueError('prompt (or 1–32 prompts) required')
    c['prompts'] = prompts
    if c['mode'] in ('attribute', 'ablate_set') and not isinstance(c.get('target_token'), str): raise ValueError('target_token required')
    if c['mode'] == 'ablate_set':
        units = c.get('units')
        if not isinstance(units, list) or not 1 <= len(units) <= 4096 or any(not isinstance(u, (list, dict)) for u in units):
            raise ValueError('units: a list of [layer, unit] pairs (or {"layer", "unit"})')
        c['units'] = [(int(u[0]), int(u[1])) if isinstance(u, list) else (int(u['layer']), int(u['unit'])) for u in units]
        c['layers'] = sorted({u[0] for u in c['units']})
        if type(c['control_seeds']) is not int or not 0 <= c['control_seeds'] <= 100: raise ValueError('control_seeds: 0–100')
    if c['mode'] == 'steer':
        if not isinstance(c.get('unit'), (list, dict)): raise ValueError('unit: [layer, unit] to steer')
        u = c['unit']; c['unit'] = (int(u[0]), int(u[1])) if isinstance(u, list) else (int(u['layer']), int(u['unit']))
        c['layers'] = [c['unit'][0]]
        strengths = c.get('strengths', [-2, -1, 0, 1, 2, 4])
        if not isinstance(strengths, list) or not 1 <= len(strengths) <= 12 or any(type(s) not in (int, float) for s in strengths):
            raise ValueError('strengths: 1–12 numbers')
        c['strengths'] = strengths
        if c.get('scale', 'maximum') not in ('maximum', 'absolute'): raise ValueError('scale: maximum or absolute')
    return c


def _target(tokenizer, text):
    ids = tokenizer.encode(text, add_special_tokens=False)
    if len(ids) != 1: raise ValueError(f'target_token {text!r} is {len(ids)} tokens; use one token (include a leading space if needed)')
    return ids[0]


def _top(tokenizer, logp, count=5):
    import numpy as np
    p = np.exp(np.array(logp))
    order = np.argsort(-p)[:count]
    return [dict(token=tokenizer.decode([int(i)]), probability=round(float(p[i]), 5)) for i in order]


def run(config, folder, load_model, progress):
    import mlx.core as mx
    import numpy as np
    c = validate(config)
    started = time.time()
    model, tokenizer, model_config, captured, collecting, info = load_model(c['hook'], c['layers'])
    active = load_model.state['active']
    layers = info['layers']

    def logprobs(ids):
        logits = model(mx.array([ids]))[0, -1].astype(mx.float32)
        return logits - mx.logsumexp(logits)

    if c['mode'] == 'attribute':
        target = _target(tokenizer, c['target_token'])
        totals = None
        rows = []
        for n, prompt in enumerate(c['prompts']):
            ids = tokenizer.encode(prompt)
            captured.clear(); collecting[0] = True
            model(mx.array([ids]))
            acts = {layer: captured[layer] for layer in layers}
            collecting[0] = False

            def objective(deltas):
                for layer, delta in zip(layers, deltas):
                    active[layer] = lambda h, d=delta: h + d.astype(h.dtype)
                out = logprobs(ids)[target]
                return out

            zeros = [mx.zeros(acts[layer].shape, dtype=mx.float32) for layer in layers]
            grads = mx.grad(objective)(zeros)
            active.clear(); collecting[0] = True
            scores = mx.stack([(acts[layer].astype(mx.float32) * g).sum(axis=(0, 1)) for layer, g in zip(layers, grads)])  # [layers, units]
            last = mx.stack([acts[layer][0, -1].astype(mx.float32) for layer in layers])
            mx.eval(scores, last)
            totals = np.array(scores) if totals is None else totals + np.array(scores)
            rows.append(dict(prompt=prompt, target_probability=float(mx.exp(logprobs(ids)[target]).item())))
            progress(f'Attribution: prompt {n + 1} of {len(c["prompts"])}', (n + 1) / len(c['prompts']))
        flat = totals.reshape(-1)
        order = np.argsort(-np.abs(flat))[:c['top']]
        width = totals.shape[1]
        ranked = [dict(layer=layers[i // width], unit=int(i % width), attribution=round(float(flat[i]), 5),
                       direction='toward' if flat[i] > 0 else 'against') for i in order]
        return dict(attribution=dict(target_token=c['target_token'], prompts=rows, units=ranked, layers=layers, hook=c['hook'],
                                     total_positive=float(flat[flat > 0].sum()), total_negative=float(flat[flat < 0].sum())),
                    hook=info, note='Activation x gradient of log P(target), summed over positions and prompts: a first-order estimate of each unit\'s effect, not a measured one. Check with ablate_set.')

    if c['mode'] == 'ablate_set':
        target = _target(tokenizer, c['target_token'])
        width = None
        captured.clear(); model(mx.array([tokenizer.encode('x')])); width = int(captured[layers[0]].shape[-1])
        collecting[0] = False
        rng = np.random.default_rng(c.get('seed', 0))

        def install(chosen):
            active.clear()
            by_layer = {}
            for layer, unit in chosen: by_layer.setdefault(layer, []).append(unit)
            for layer, units in by_layer.items():
                mask = np.ones(width, 'float32'); mask[units] = 0
                active[layer] = lambda h, m=mx.array(mask): h * m.astype(h.dtype)

        def measure(chosen):
            install(chosen) if chosen else active.clear()
            out = []
            for prompt in c['prompts']:
                lp = logprobs(tokenizer.encode(prompt))
                out.append(dict(probability=float(mx.exp(lp[target]).item()), top=_top(tokenizer, lp)))
            active.clear()
            return out

        baseline = measure([])
        ablated = measure(c['units'])
        per_layer = {}
        for layer, _ in c['units']: per_layer[layer] = per_layer.get(layer, 0) + 1
        controls = []
        for seed in range(c['control_seeds']):
            chosen = [(layer, int(u)) for layer, count in per_layer.items() for u in rng.choice(width, size=count, replace=False)]
            controls.append([r['probability'] for r in measure(chosen)])
            progress(f'Random control {seed + 1} of {c["control_seeds"]}', (seed + 1) / max(c['control_seeds'], 1))
        controls = np.array(controls) if controls else np.zeros((0, len(c['prompts'])))
        prompts = []
        for i, prompt in enumerate(c['prompts']):
            row = dict(prompt=prompt, baseline=baseline[i], ablated=ablated[i])
            if len(controls):
                col = controls[:, i]
                row['random_control'] = dict(mean=float(col.mean()), low=float(np.quantile(col, 0.025)), high=float(np.quantile(col, 0.975)),
                                             values=[round(float(v), 5) for v in col])
            prompts.append(row)
        mean = lambda key: float(np.mean([p[key]['probability'] for p in prompts]))
        return dict(ablate_set=dict(target_token=c['target_token'], units=[list(u) for u in c['units']], per_layer=per_layer, prompts=prompts,
                                    baseline_probability=mean('baseline'), ablated_probability=mean('ablated'),
                                    random_control_probability=float(controls.mean()) if len(controls) else None,
                                    control_seeds=c['control_seeds'], hook=c['hook']),
                    hook=info, note='Units zeroed at every position. Random controls zero the same number of units from the same layers.')

    # steer
    layer, unit = c['unit']
    maximum = None
    if c.get('scale', 'maximum') == 'maximum':
        maximum = c.get('maximum')
        if maximum is None and c.get('atlas'):
            from .atlas import read_page
            page = read_page(Path(c['lab_root']) / c['atlas'], layer, unit)
            maximum = page['poles']['positive']['maximum']
        if maximum is None:
            # Its largest activation on the prompts themselves.
            values = []
            for prompt in c['prompts']:
                captured.clear(); model(mx.array([tokenizer.encode(prompt)]))
                values.append(float(mx.max(mx.abs(captured[layer][0, :, unit])).item()))
            maximum = max(values) or 1.0
    captured.clear(); model(mx.array([tokenizer.encode('x')])); width = int(captured[layer].shape[-1])
    eos = getattr(tokenizer, 'eos_token_ids', None) or {tokenizer.eos_token_id}
    collecting[0] = False
    outputs = []
    for prompt in c['prompts']:
        for strength in c['strengths']:
            amount = strength * (maximum if maximum is not None else 1.0)
            vector = np.zeros(width, 'float32'); vector[unit] = amount
            add = lambda h, v=mx.array(vector): h + v.astype(h.dtype)
            active[layer] = add if strength else (lambda h: h)
            ids = tokenizer.encode(prompt)
            generated = []
            for _ in range(c['max_tokens']):
                token = int(mx.argmax(model(mx.array([ids + generated]))[0, -1]).item())
                if token in eos: break
                generated.append(token)
            outputs.append(dict(prompt=prompt, strength=strength, added=round(float(amount), 4), text=tokenizer.decode(generated)))
            progress(f'Steering at {strength}', len(outputs) / (len(c['prompts']) * len(c['strengths'])))
    active.clear()
    return dict(steer=dict(layer=layer, unit=unit, scale=c.get('scale', 'maximum'), maximum=maximum, outputs=outputs, hook=c['hook']),
                hook=info, note='Added at every position on every forward pass. Greedy decoding.')
