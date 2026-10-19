"""Lossless speculative decoding with the model's own MTP head (Qwen3.5/3.6/3.8 family).

A dense 27B at 4 bits reads ~15 GB of weights per token, which caps plain decoding near
40 tok/s on an M5 Max. Each round here drafts `k` tokens with the small MTP head, checks
all of them with one target forward over k+1 tokens, and keeps the longest prefix the
target agrees with, so several tokens come out per weight read.

Output is distributed exactly as plain sampling with the same settings: drafts are
accepted with probability min(1, p/q) and a rejection resamples from max(p - q, 0)
(Leviathan et al., 2023); at temperature 0 this reduces to greedy agreement.

The hybrid layers are the hard part. Gated-DeltaNet layers carry a recurrent state that
cannot be trimmed like a KV cache, so each verify records the layer's projected inputs and
a rejected tail is undone by replaying only the accepted steps from the pre-verify state
(no matmuls, ~150 MB of state math). Attention layers just trim their KV cache.

Plugs into mlx_lm without forking it: `mlx_lm.generate.stream_generate` calls the module
global `speculative_generate_step` whenever a draft model is attached, and `install`
points that global here for MTP drafters.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Callable, Generator, List, Optional, Tuple

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models import qwen3_5
from mlx_lm.models.cache import KVCache, make_prompt_cache
from mlx_lm.models.gated_delta import gated_delta_update
from mlx_lm.sample_utils import apply_min_p, apply_top_k, apply_top_p

_log = logging.getLogger(__name__)


# --- Sampling ------------------------------------------------------------------------


@dataclass
class SamplerSpec:
    """A sampler that remembers its settings, so drafts can be accepted losslessly."""

    sampler: Callable[[mx.array], mx.array]
    temperature: float = 0.0
    top_p: float = 0.0
    min_p: float = 0.0
    top_k: int = 0
    exact: bool = True  # False when the chain has a step we cannot reproduce (XTC)

    def __call__(self, logprobs: mx.array) -> mx.array:
        return self.sampler(logprobs)

    def filtered(self, logits: mx.array) -> mx.array:
        """Logprobs after the same filters mlx_lm's sampler applies, in the same order."""
        logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        if 0 < self.top_p < 1.0:
            logprobs = apply_top_p(logprobs, self.top_p)
        if self.min_p != 0.0:
            logprobs = apply_min_p(logprobs, self.min_p, 1)
        if self.top_k > 0:
            logprobs = apply_top_k(logprobs, self.top_k)
        return logprobs

    def probs(self, logits: mx.array) -> mx.array:
        return mx.softmax(self.filtered(logits.astype(mx.float32)) / self.temperature, axis=-1)


def wrap_sampler_factory(make_sampler: Callable[..., Any]) -> Callable[..., Any]:
    """Wrap mlx_lm.server._make_sampler so the sampler carries its parameters."""

    def factory(args, tokenizer):
        sampling = args.sampling
        return SamplerSpec(
            sampler=make_sampler(args, tokenizer),
            temperature=float(sampling.temperature or 0.0),
            top_p=float(sampling.top_p or 0.0),
            min_p=float(sampling.min_p or 0.0),
            top_k=int(sampling.top_k or 0),
            exact=not (sampling.xtc_probability or 0.0) > 0.0,
        )

    return factory


# --- Gated-DeltaNet capture and rollback ----------------------------------------------


@dataclass
class _GDNRecord:
    layer: Any
    cache: Any
    old_conv: Optional[mx.array]
    old_state: Optional[mx.array]
    qkv: mx.array
    a: mx.array
    b: mx.array


_capture: Optional[List[_GDNRecord]] = None


def _gdn_call(self, inputs: mx.array, mask: Optional[mx.array] = None, cache: Optional[Any] = None):
    """mlx_lm's GatedDeltaNet.__call__ (0.31), plus recording what a rollback replays."""
    B, S, _ = inputs.shape
    if self.sharding_group is not None:
        inputs = qwen3_5.sum_gradients(self.sharding_group)(inputs)
    qkv = self.in_proj_qkv(inputs)
    z = self.in_proj_z(inputs).reshape(B, S, self.num_v_heads, self.head_v_dim)
    b = self.in_proj_b(inputs)
    a = self.in_proj_a(inputs)

    if _capture is not None and cache is not None:
        _capture.append(_GDNRecord(self, cache, cache[0], cache[1], qkv, a, b))

    if cache is not None and cache[0] is not None:
        conv_state = cache[0]
    else:
        conv_state = mx.zeros((B, self.conv_kernel_size - 1, self.conv_dim), dtype=inputs.dtype)

    if mask is not None:
        qkv = mx.where(mask[..., None], qkv, 0)
    conv_input = mx.concatenate([conv_state, qkv], axis=1)
    if cache is not None:
        n_keep = self.conv_kernel_size - 1
        if cache.lengths is not None:
            ends = mx.clip(cache.lengths, 0, S)
            positions = (ends[:, None] + mx.arange(n_keep))[..., None]
            cache[0] = mx.take_along_axis(conv_input, positions, axis=1)
        else:
            cache[0] = mx.contiguous(conv_input[:, -n_keep:, :])
    q, k, v, state = _gdn_core(self, conv_input, B, S, cache[1] if cache else None)
    out, state = gated_delta_update(
        q, k, v, a, b, self.A_log, self.dt_bias, state, mask, use_kernel=not self.training
    )
    if cache is not None:
        cache[1] = state
        cache.advance(S)
    out = self.norm(out, z)
    out = self.out_proj(out.reshape(B, S, -1))
    if self.sharding_group is not None:
        out = mx.distributed.all_sum(out, group=self.sharding_group)
    return out


def _gdn_core(layer, conv_input: mx.array, B: int, S: int, state: Optional[mx.array]):
    conv_out = nn.silu(layer.conv1d(conv_input))
    q, k, v = [
        t.reshape(B, S, h, d)
        for t, h, d in zip(
            mx.split(conv_out, [layer.key_dim, 2 * layer.key_dim], -1),
            [layer.num_k_heads, layer.num_k_heads, layer.num_v_heads],
            [layer.head_k_dim, layer.head_k_dim, layer.head_v_dim],
        )
    ]
    inv_scale = k.shape[-1] ** -0.5
    q = (inv_scale**2) * mx.fast.rms_norm(q, None, 1e-6)
    k = inv_scale * mx.fast.rms_norm(k, None, 1e-6)
    return q, k, v, state


def _replay(record: _GDNRecord, keep: int) -> None:
    """Set the layer's cache to its state after the first `keep` verified tokens."""
    layer, cache = record.layer, record.cache
    B = record.qkv.shape[0]
    conv_state = record.old_conv
    if conv_state is None:
        conv_state = mx.zeros((B, layer.conv_kernel_size - 1, layer.conv_dim), dtype=record.qkv.dtype)
    conv_input = mx.concatenate([conv_state, record.qkv[:, :keep]], axis=1)
    cache[0] = mx.contiguous(conv_input[:, -(layer.conv_kernel_size - 1):, :])
    q, k, v, state = _gdn_core(layer, conv_input, B, keep, record.old_state)
    _, state = gated_delta_update(
        q, k, v, record.a[:, :keep], record.b[:, :keep], layer.A_log, layer.dt_bias, state, None,
        use_kernel=True,
    )
    cache[1] = state


# --- The speculative loop -----------------------------------------------------------


class _Target:
    """The pieces of a qwen3_5 target the loop needs: hidden states, then logits."""

    def __init__(self, model: Any, drafter: Any):
        self.text = getattr(model, "language_model", model)
        self.drafter = drafter

    def hidden(self, tokens: mx.array, cache: List[Any]) -> mx.array:
        return self.text.model(tokens, cache)

    def logits(self, hidden: mx.array) -> mx.array:
        return self.drafter.logits(hidden)


class _Rollback:
    """Undo a verify past its first `keep` tokens."""

    def __init__(self, cache: List[Any], records: List[_GDNRecord], verified: int):
        self.cache, self.records, self.verified = cache, records, verified

    def keep(self, keep: int) -> None:
        if keep >= self.verified:
            return
        for c in self.cache:
            if isinstance(c, KVCache):
                c.trim(self.verified - keep)
        for record in self.records:
            _replay(record, keep)
        self.verified = keep


def mtp_generate_step(
    prompt: mx.array,
    model: nn.Module,
    draft_model: nn.Module,
    *,
    num_draft_tokens: int = 3,
    max_tokens: int = 256,
    sampler: Optional[Callable[[mx.array], mx.array]] = None,
    logits_processors: Optional[List[Callable[[mx.array, mx.array], mx.array]]] = None,
    prompt_cache: Optional[Any] = None,
    prefill_step_size: int = 512,
    **_: Any,
) -> Generator[Tuple[int, mx.array, bool], None, None]:
    """Same contract as mlx_lm's speculative_generate_step: yields (token, logprobs, from_draft).

    When the consumer stops, the cache covers exactly the prompt plus every token yielded,
    which is what the server's prompt cache assumes.
    """
    from mlx_lm.generate import generation_stream

    spec = sampler if isinstance(sampler, SamplerSpec) else None
    greedy = spec is None or spec.temperature == 0.0
    if spec is None and sampler is not None:
        _log.debug("unknown sampler; drafting greedily against an argmax target")
    k_draft = max(1, int(num_draft_tokens))
    if prompt_cache is None:
        prompt_cache = make_prompt_cache(model) + draft_model.make_cache()
    target_cache, mtp_cache = prompt_cache[:-1], prompt_cache[-1]
    target = _Target(model, draft_model)

    def sample(logits: mx.array) -> Tuple[mx.array, Optional[mx.array]]:
        """A token from these logits, and the distribution it was drawn from."""
        if greedy:
            return mx.argmax(logits, axis=-1), None
        probs = spec.probs(logits)
        return mx.random.categorical(mx.log(probs)), probs

    def logprobs_of(logits: mx.array) -> mx.array:
        return logits - mx.logsumexp(logits, axis=-1, keepdims=True)

    def target_offset() -> int:
        for c in target_cache:
            if isinstance(c, KVCache):
                return c.offset
        return 0

    with mx.stream(generation_stream):
        # MTP pairs (h_i, x_{i+1}) stay in lockstep with the target: the drafter cache holds
        # one entry per target position except the last, whose hidden waits in `last_hidden`.
        last_hidden = getattr(mtp_cache, "svm_last_hidden", None)
        if last_hidden is None or mtp_cache.offset != target_offset() - 1:
            mtp_cache = prompt_cache[-1] = KVCache()
            last_hidden = None

        # Prefill.
        tokens = prompt.reshape(-1)
        for start in range(0, tokens.size, prefill_step_size):
            chunk = tokens[start : start + prefill_step_size][None]
            hidden = target.hidden(chunk, target_cache)
            pair_hidden = hidden[:, :-1] if last_hidden is None else mx.concatenate([last_hidden, hidden[:, :-1]], 1)
            pair_tokens = chunk[:, 1:] if last_hidden is None else chunk
            if pair_tokens.size:
                draft_model(pair_hidden, pair_tokens, mtp_cache)
            last_hidden = hidden[:, -1:]
            mx.eval(last_hidden, _cache_arrays(target_cache + [mtp_cache]))
        mtp_cache.svm_last_hidden = last_hidden

        first_logits = target.logits(last_hidden)[0, -1]
        token, _ = sample(first_logits)
        token = token.reshape(1, 1)
        pending_hidden, pending_tokens = last_hidden, token
        produced = 0

        # Hand out the first token. The target has not seen it yet, so it is "unfed".
        unfed = token
        mx.eval(unfed)
        try:
            yield unfed.item(), logprobs_of(first_logits), False
        except GeneratorExit:
            _feed(target, draft_model, unfed, target_cache, mtp_cache, pending_hidden, pending_tokens)
            return
        produced += 1

        while produced < max_tokens:
            k = min(k_draft, max_tokens - produced)

            # Draft: commit the pending pairs, then chain k-1 provisional steps.
            g = draft_model(pending_hidden, pending_tokens, mtp_cache)[:, -1:]
            committed = mtp_cache.offset
            drafts, qs = [], []
            for i in range(k):
                d, q = sample(target.logits(g)[0, -1])
                drafts.append(d.reshape(1, 1))
                qs.append(q)
                if i + 1 < k:
                    g = draft_model(g, drafts[-1], mtp_cache)
            mtp_cache.trim(mtp_cache.offset - committed)

            # Verify all drafts in one target forward.
            global _capture
            _capture = records = []
            try:
                verify_in = mx.concatenate([unfed] + drafts, axis=1)
                hidden = target.hidden(verify_in, target_cache)
            finally:
                _capture = None
            logits = target.logits(hidden)[0]  # (k+1, V)
            draft_ids = mx.concatenate(drafts, axis=1)[0]  # (k,)

            if greedy:
                choice = mx.argmax(logits, axis=-1)
                agree = (choice[:k] == draft_ids).astype(mx.int32)
                n_ok = mx.sum(mx.cumprod(agree))
                bonus = choice
            else:
                p = spec.probs(logits)  # (k+1, V)
                q = mx.stack(qs)  # (k, V)
                rows = mx.arange(k)
                ratio = p[rows, draft_ids] / mx.maximum(q[rows, draft_ids], 1e-20)
                agree = (mx.random.uniform(shape=(k,)) < ratio).astype(mx.int32)
                n_ok = mx.sum(mx.cumprod(agree))
                residual = mx.maximum(p[:k] - q, 0.0)
                mass = residual.sum(-1, keepdims=True)
                residual = mx.where(mass > 0, residual / mx.maximum(mass, 1e-20), p[:k])
                dist = mx.concatenate([residual, p[k:]], axis=0)
                bonus = mx.random.categorical(mx.log(dist))
            mx.eval(n_ok, bonus, draft_ids)
            j = int(n_ok.item())

            rollback = _Rollback(target_cache, records, k + 1)
            rollback.keep(j + 1)  # cache now covers unfed + the j accepted drafts
            out = draft_ids[:j].tolist() + [int(bonus[j].item())]
            z = mx.array([[out[-1]]], dtype=mx.uint32)

            # Pairs for the next round: (h at x_i, x_{i+1}) for the accepted run, then z.
            pending_hidden = hidden[:, : j + 1]
            pending_tokens = mx.concatenate(drafts[:j] + [z.astype(drafts[0].dtype)], axis=1)
            unfed = z.astype(verify_in.dtype)

            def settle(i: int) -> None:
                """The consumer holds out[:i+1]; make the caches cover exactly that."""
                if i < j:
                    rollback.keep(i + 2)
                    draft_model(hidden[:, : i + 1], verify_in[:, 1 : i + 2], mtp_cache)
                    mtp_cache.svm_last_hidden = hidden[:, i + 1 : i + 2]
                    mx.eval(mtp_cache.svm_last_hidden, _cache_arrays(target_cache + [mtp_cache]))
                else:
                    _feed(target, draft_model, unfed, target_cache, mtp_cache, pending_hidden, pending_tokens)

            for i, t in enumerate(out):
                try:
                    yield t, logprobs_of(logits[i]), i < j
                except GeneratorExit:
                    settle(i)
                    return
                produced += 1
                if produced >= max_tokens:
                    settle(i)
                    return

        # The budget ran out right after the first token.
        _feed(target, draft_model, unfed, target_cache, mtp_cache, pending_hidden, pending_tokens)


def _feed(target, drafter, token, target_cache, mtp_cache, pair_hidden, pair_tokens) -> None:
    """Run the target over a token the consumer already has, keeping the drafter in step.

    `pair_hidden`/`pair_tokens` are the drafter pairs still owed, ending with (h, token).
    """
    hidden = target.hidden(token, target_cache)
    drafter(pair_hidden, pair_tokens, mtp_cache)
    mtp_cache.svm_last_hidden = hidden[:, -1:]
    mx.eval(mtp_cache.svm_last_hidden, _cache_arrays(target_cache + [mtp_cache]))


def _cache_arrays(caches: List[Any]) -> List[mx.array]:
    arrays = []
    for c in caches:
        if isinstance(c, KVCache):
            if c.keys is not None:
                arrays += [c.keys, c.values]
        else:
            arrays += [a for a in getattr(c, "cache", []) if a is not None]
    return arrays


# --- Wiring ---------------------------------------------------------------------------


def install(generate_module: Any) -> None:
    """Route MTP drafters through `mtp_generate_step`; anything else keeps mlx_lm's path."""
    if getattr(generate_module, "_dyno_mtp_installed", False):
        return
    original = generate_module.speculative_generate_step

    def speculative_generate_step(prompt, model, draft_model, **kwargs):
        if getattr(draft_model, "is_mtp_drafter", False) and not kwargs.get("logits_processors"):
            sampler = kwargs.get("sampler")
            if not isinstance(sampler, SamplerSpec) or sampler.exact:
                return mtp_generate_step(prompt, model, draft_model, **kwargs)
        if getattr(draft_model, "is_mtp_drafter", False):
            return _plain(prompt, model, draft_model, generate_module, **kwargs)
        return original(prompt, model, draft_model, **kwargs)

    generate_module.speculative_generate_step = speculative_generate_step
    qwen3_5.GatedDeltaNet.__call__ = _gdn_call
    generate_module._dyno_mtp_installed = True


def _plain(prompt, model, draft_model, generate_module, **kwargs):
    """Settings speculation cannot reproduce exactly: decode normally, drop the drafter cache."""
    kwargs.pop("num_draft_tokens", None)
    cache = kwargs.get("prompt_cache")
    if cache is not None:
        kwargs["prompt_cache"] = cache[:-1]
        cache[-1] = KVCache()  # stale from here on; rebuilt on the next speculative request
    for token, logprobs in generate_module.generate_step(prompt, model, **kwargs):
        yield token, logprobs, False
