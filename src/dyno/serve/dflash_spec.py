"""Speculative decoding with a DFlash2 block drafter, losslessly, for Qwen3.5/3.6/3.8 targets.

DFlash2 (https://inco.ai/blog/dflash2/) drafts a whole block in one pass of a small non-causal
model conditioned on hidden states from five of the target's layers, then a selector picks one
path through the top-16 candidates of every position. Each round here:

    draft   [z, mask x k] -> k tokens, and q: the distribution each was drawn from
    verify  the target runs [z, d1..dk] once, recording its feature layers
    accept  d_i with probability min(1, p_i/q_i); the first rejection resamples from
            max(p - q, 0) (greedy: while the target's argmax agrees)
    commit  roll Gated-DeltaNet and KV caches back to the accepted prefix; the accepted
            positions' features become the drafter's next context

The target, its cache, rollback and sampling filters are shared with `speculative` (MTP).
The drafter's state lives in the server's prompt cache next to the target's, and covers
exactly the positions the target has processed, so a cached prompt keeps drafting well.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Generator, List, Optional, Tuple

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.cache import KVCache, make_prompt_cache

from . import progress

from . import dflash_tree, speculative as S
from .dflash.dflash2 import DFlash2DraftModel, DFlash2DraftModelArgs, remap_dflash2_codebook_weights
from .dflash.model import ContextOnlyDraftKVCache

_log = logging.getLogger(__name__)

SINK, WINDOW = 64, 2048  # draft context kept: first SINK positions and the last WINDOW
_TAPS: Optional[dict] = None  # layer index -> output, while a target pass records features


class DFlashState:
    """The drafter's part of a prompt cache: its context caches, the target features not yet
    appended to them, and the target position they lead up to."""

    def __init__(self, layers: int):
        self.layers = [ContextOnlyDraftKVCache(sink_size=SINK, window_size=WINDOW) for _ in range(layers)]
        self.pending: Optional[mx.array] = None
        self.position = 0  # target positions covered by context + pending

    # mlx_lm's prompt cache treats every entry as a cache; this one is never trimmed in place.
    def is_trimmable(self) -> bool:
        return False

    @property
    def state(self) -> List[mx.array]:
        arrays = [a for c in self.layers for a in (c.keys, c.values) if a is not None]
        return arrays + ([self.pending] if self.pending is not None else [])

    @property
    def nbytes(self) -> int:
        return sum(a.nbytes for a in self.state)

    def add(self, features: mx.array) -> None:
        self.pending = features if self.pending is None else mx.concatenate([self.pending, features], axis=1)
        self.position += features.shape[1]

    def drop(self, n: int) -> None:
        """Forget the last n positions (only ever still-pending ones)."""
        if n:
            self.pending = self.pending[:, : self.pending.shape[1] - n]
            self.position -= n


class DFlashDrafter(nn.Module):
    """Stands in for mlx_lm's `draft_model` so the server routes requests to the speculative path."""

    is_dflash_drafter = True

    def __init__(self, model: DFlash2DraftModel, target: Any):
        super().__init__()
        self.model = model
        self._text = getattr(target, "language_model", target)
        self.layer_ids = list(model.target_layer_ids)
        self.block_size = int(model.block_size)
        self.mask_token_id = int(model.mask_token_id)
        _install_taps(self._text.model, self.layer_ids)

    def make_cache(self) -> List[Any]:
        return [DFlashState(len(self.model.layers))]

    def features(self) -> mx.array:
        return mx.concatenate([_TAPS[i] for i in self.layer_ids], axis=-1)

    def flush(self, state: DFlashState) -> None:
        """Append pending context without drafting (keeps prefill memory bounded)."""
        if state.pending is not None:
            self.model.advance_projected_context_cache(
                draft_context=self.model.project_target_hidden(state.pending), cache=state.layers
            )
            state.pending = None

    def _draft(self, state: DFlashState, anchor: mx.array, k: int) -> Tuple[mx.array, mx.array]:
        """The drafter's hidden states and logits for the k positions after `anchor`,
        consuming the pending context."""
        text = self._text
        block = mx.concatenate([anchor.astype(mx.uint32), mx.full((1, k), self.mask_token_id, dtype=mx.uint32)], axis=1)
        context = self.model.project_target_hidden(state.pending)
        state.pending = None
        hidden = self.model.forward_projected_context(
            noise_embedding=text.model.embed_tokens(block), draft_context=context, cache=state.layers
        )
        logits = text.lm_head(hidden[:, 1:]) if not text.args.tie_word_embeddings else \
            text.model.embed_tokens.as_linear(hidden[:, 1:])
        return hidden[:, 1:], logits

    def propose(self, state: DFlashState, anchor: mx.array, k: int, temperature: float, capture_q: bool):
        """k drafted tokens after `anchor`: the selector's path through the candidates."""
        hidden, logits = self._draft(state, anchor, k)
        return self.model.select_proposal(
            draft_hidden=hidden, logits=logits, anchor_ids=anchor.reshape(1),
            temperature=temperature, capture_q=capture_q,
        )

    def propose_tree(self, state: DFlashState, anchor: mx.array, k: int, max_nodes: int) -> "dflash_tree.Tree":
        """The likeliest prefixes of the selector's lattice over k positions, as a tree."""
        hidden, logits = self._draft(state, anchor, k)
        args = (self.model.candidate_selector, hidden, self.model.compute_logits(logits), anchor)
        if max_nodes > k:
            return dflash_tree.build(*dflash_tree.lattice(*args), max_nodes=max_nodes)
        tree = dflash_tree.build_gpu(*dflash_tree.lattice_arrays(*args), max_nodes=max_nodes)
        mx.async_eval(tree.arrays())  # the drafter runs while the host queues the verify
        return tree


def _install_taps(inner: Any, layer_ids: List[int]) -> None:
    """Record the outputs of the given target layers while `_TAPS` is a dict."""
    for lid in layer_ids:
        layer = inner.layers[lid]
        if getattr(layer, "_dyno_tap", None) is not None:
            continue
        base = type(layer)

        def call(self, *args, _base=base, **kwargs):
            out = _base.__call__(self, *args, **kwargs)
            if _TAPS is not None:
                _TAPS[self._dyno_tap] = out
            return out

        layer.__class__ = type(f"Tapped{base.__name__}", (base,), {"__call__": call})
        layer._dyno_tap = lid


def load_dflash_drafter(path: str | os.PathLike, target: Any, bits: int = 8) -> DFlashDrafter:
    """Load a DFlash2 checkpoint; linear layers are quantized to `bits` (8 keeps acceptance)."""
    path = Path(path)
    config = json.loads((path / "config.json").read_text())
    model = DFlash2DraftModel(DFlash2DraftModelArgs.from_dict(config))
    weights = {}
    for shard in sorted(path.glob("*.safetensors")):
        weights.update(mx.load(str(shard)))
    model.load_weights(list(remap_dflash2_codebook_weights(weights).items()), strict=True)
    if bits:
        nn.quantize(model, group_size=64, bits=bits,
                    class_predicate=lambda _, m: isinstance(m, nn.Linear) and m.weight.shape[-1] % 64 == 0)
    mx.eval(model.parameters())
    return DFlashDrafter(model, target)


def find_drafter(base: str) -> Optional[Path]:
    """A downloaded DFlash2 drafter for this base model in the Hugging Face cache, if any."""
    hub = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache" / "huggingface" / "hub"))
    for snapshot in sorted(hub.glob(f"models--*--{base}-DFlash2/snapshots/*")):
        if (snapshot / "config.json").exists() and any(snapshot.glob("*.safetensors")):
            return snapshot
    return None


def dflash_generate_step(
    prompt: mx.array,
    model: nn.Module,
    draft_model: DFlashDrafter,
    *,
    num_draft_tokens: int = 7,
    max_tokens: int = 256,
    sampler: Optional[Any] = None,
    prompt_cache: Optional[Any] = None,
    prefill_step_size: int = 2048,
    **_: Any,
) -> Generator[Tuple[int, mx.array, bool], None, None]:
    """Same contract as mlx_lm's speculative_generate_step: yields (token, logprobs, from_draft).

    When the consumer stops, the caches cover exactly the prompt plus every token yielded.
    """
    draft_model.stats = None
    try:
        yield from _dflash_loop(prompt, model, draft_model, num_draft_tokens, max_tokens, sampler,
                                prompt_cache, prefill_step_size)
    finally:
        stats = getattr(draft_model, "stats", None)
        if stats and stats["rounds"]:
            from .instrument import registry

            registry.note_speculation(stats["rounds"], stats["drafted"], stats["accepted"])
            trees = stats.get("tree_rounds", 0)
            _log.info(
                "DFlash2: %d tokens in %d rounds (%.2f per round), %d/%d drafts accepted%s%s%s",
                stats["tokens"], stats["rounds"], stats["tokens"] / stats["rounds"],
                stats["accepted"], stats["drafted"], f", {trees} rounds as trees" if trees else "",
                " (drafter context reset)" if stats["reset"] else "", S.copy_summary(draft_model),
            )


# Draft length when --num-draft-tokens isn't given; set by `dyno serve` on GPUs with neural
# accelerators, where a 16-token verify costs about what an 8-token one does. DFlash2 drafts a
# whole block in one pass whatever its length, so the policy may go past the trained block of 8
# (positions 8-15 are still accepted often on reasoning and edits).
DEPTH: Optional[int] = None
DEEP_DEPTH = 15
# Draft trees instead of chains (dflash_tree); set with DEPTH, where a 16-row verify is cheap.
TREES = False


def prior(nax: bool) -> dict:
    """Round cost per draft length in plain steps: the verify, plus ~0.35 for one drafter pass."""
    from .copy_draft import VerifyCost

    cost = VerifyCost(nax=nax)
    return {0: 1.0, **{k: cost(k + 1, None) + 0.35 for k in range(1, DEEP_DEPTH + 1)}}


def _accept_tree(tree, logits, logprobs, greedy, spec) -> Tuple[List[int], int]:
    """(verify rows of the accepted path from the anchor, the bonus token after it)."""
    if greedy:
        choice = mx.argmax(logits, axis=-1)
        mx.eval(choice, logprobs, tree.token_ids, tree.parents)
        tree.materialize()
        choice = choice.tolist()
        rows = tree.walk_greedy(choice)
        return rows, choice[rows[-1]]
    p = spec.probs(logits)
    child_p = p[tree.parents[1:], tree.token_ids]  # each node's probability at its parent's row
    uniforms = mx.random.uniform(shape=(tree.L, dflash_tree.CHILDREN))
    mx.eval(child_p, uniforms, logprobs, tree.token_ids, tree.parents)
    tree.materialize()
    pairs = [(tree.row_parent[r], tree.row_token[r]) for r in range(1, tree.L)]
    rows, removed = tree.walk_sampled(dict(zip(pairs, child_p.tolist())), uniforms.tolist())
    last = p[rows[-1]]
    if removed:
        last = last.at[mx.array(removed)].multiply(0.0)
    return rows, int(mx.random.categorical(mx.log(last)).item())


def _run_target(draft_model, target_cache, tokens):
    """Hidden states and feature-layer outputs of the target over `tokens`."""
    global _TAPS
    _TAPS = {}
    try:
        hidden = draft_model._text.model(tokens, target_cache)
        return hidden, draft_model.features()
    finally:
        _TAPS = None


def _dflash_prefill(prompt, draft_model, prompt_cache, prefill_step_size):
    """Run the target over `prompt`, extending its cache and the drafter's context features.
    Returns the last chunk's hidden states and the drafter state."""
    target_cache, state = prompt_cache[:-1], prompt_cache[-1]
    offset = next((c.offset for c in target_cache if isinstance(c, KVCache)), 0)
    if not isinstance(state, DFlashState) or state.position != offset:
        # Stale (the target cache moved without us): restart the drafter's context here.
        state = prompt_cache[-1] = DFlashState(len(draft_model.model.layers))
        state.position = offset
    tokens = prompt.reshape(-1)
    hidden = None
    for start in range(0, tokens.size, prefill_step_size):
        draft_model.flush(state)
        chunk = tokens[start : start + prefill_step_size]
        hidden, feats = _run_target(draft_model, target_cache, chunk[None])
        state.add(feats)
        mx.eval(hidden, state.pending, S._cache_arrays(target_cache))
        progress.advance(chunk.size)
    return hidden, state


def dflash_prefill(prompt, model, draft_model, prompt_cache, prefill_step_size=512):
    """Extend the caches by `prompt` without generating (prompt-cache checkpoints)."""
    from mlx_lm.generate import generation_stream

    with mx.stream(generation_stream):
        _dflash_prefill(prompt, draft_model, prompt_cache, prefill_step_size)


def _dflash_loop(prompt, model, draft_model, num_draft_tokens, max_tokens, sampler, prompt_cache, prefill_step_size):
    global _TAPS
    from mlx_lm.generate import generation_stream

    spec = sampler if isinstance(sampler, S.SamplerSpec) else None
    greedy = spec is None or spec.temperature == 0.0
    k_max = DEPTH or max(1, min(int(num_draft_tokens), draft_model.block_size - 1))
    if prompt_cache is None:
        prompt_cache = make_prompt_cache(model) + draft_model.make_cache()
    target_cache, state = prompt_cache[:-1], prompt_cache[-1]
    text = draft_model._text
    inner = text.model

    def target_offset() -> int:
        for c in target_cache:
            if isinstance(c, KVCache):
                return c.offset
        return 0

    def run_target(tokens: mx.array) -> Tuple[mx.array, mx.array]:
        return _run_target(draft_model, target_cache, tokens)

    def logits_of(hidden: mx.array) -> mx.array:
        return text.lm_head(hidden) if not text.args.tie_word_embeddings else inner.embed_tokens.as_linear(hidden)

    def sample(logits: mx.array) -> mx.array:
        if greedy:
            return mx.argmax(logits, axis=-1)
        return mx.random.categorical(mx.log(spec.probs(logits)))

    def logprobs_of(logits: mx.array) -> mx.array:
        return logits - mx.logsumexp(logits, axis=-1, keepdims=True)

    stats = draft_model.stats = {"rounds": 0, "drafted": 0, "accepted": 0, "tokens": 0, "reset": False}
    with mx.stream(generation_stream):
        stats["reset"] = target_offset() > 0 and not (isinstance(state, DFlashState) and state.position == target_offset())
        hidden, state = _dflash_prefill(prompt, draft_model, prompt_cache, prefill_step_size)

        first_logits = logits_of(hidden[:, -1:])[0, -1]
        z = sample(first_logits).reshape(1, 1).astype(mx.uint32)
        mx.eval(z)

        def feed(token: mx.array) -> None:
            """Run the target over a token the consumer already has."""
            _, feats = run_target(token)
            state.add(feats)
            mx.eval(state.pending, S._cache_arrays(target_cache))

        try:
            yield int(z.item()), logprobs_of(first_logits), False
        except GeneratorExit:
            feed(z)
            return
        produced = 1

        timings = getattr(draft_model, "policy", None) or S.DraftPolicy(prior=prior(S.DraftPolicy.PRIOR is S.DraftPolicy.NAX_PRIOR))
        policy = draft_model.policy = timings.fresh()
        copier = S.copier_for(draft_model, prompt, int(z.item()))
        trees = TREES and dflash_tree.supported(target_cache)
        if trees:
            dflash_tree.install()
        while produced < max_tokens:
            started = time.perf_counter()
            copy = copier and copier.propose(policy.rate(k_max), policy.unit, max_tokens - produced)
            k = len(copy.tokens) if copy else min(policy.choose(k_max), max_tokens - produced)

            tree = None
            if copy:  # tokens copied from the context
                draft_ids = mx.array(copy.tokens, dtype=mx.uint32)
            elif k == 0:  # a plain step; its features still reach the drafter through state.add
                draft_ids = mx.zeros((0,), dtype=mx.uint32)
            elif trees:  # every position, with the selector's runners-up where it is unsure
                k = k_max
                tree = draft_model.propose_tree(state, z, k, min(dflash_tree.MAX_NODES, max_tokens - produced))
                draft_ids = tree.token_ids
            else:
                proposal = draft_model.propose(state, z, k, 0.0 if greedy else spec.temperature, not greedy)
                draft_ids = proposal.token_ids.reshape(-1).astype(mx.uint32)
                q_ids, q_probs = proposal.q_token_ids, proposal.q_probs

            S._capture = records = []
            dflash_tree.ACTIVE = tree
            try:
                verify_in = mx.concatenate([z, draft_ids[None]], axis=1)
                hidden, feats = run_target(verify_in)
            finally:
                S._capture = None
                dflash_tree.ACTIVE = None
            logits = logits_of(hidden)[0]  # (k+1, V); a tree's: (nodes+1, V)

            if tree is not None:
                logprobs = logprobs_of(logits)
                path, bonus_token = _accept_tree(tree, logits, logprobs, greedy, spec)
                j = len(path) - 1
                out = [tree.row_token[r] for r in path[1:]] + [bonus_token]
                rollback = dflash_tree.Commit(target_cache, records, path, tree.L)
                feats = feats[:, mx.array(path, dtype=mx.int32)]  # from here on, rows of the path
                logprobs = logprobs[mx.array(path, dtype=mx.int32)]
            elif k == 0:
                n_ok = mx.array(0)
                bonus = mx.argmax(logits, axis=-1) if greedy else mx.random.categorical(mx.log(spec.probs(logits)))
            elif greedy:
                choice = mx.argmax(logits, axis=-1)
                n_ok = mx.sum(mx.cumprod((choice[:k] == draft_ids).astype(mx.int32)))
                bonus = choice
            else:
                p = spec.probs(logits)
                if copy:
                    q = S.one_hot(draft_ids, p)
                else:
                    q = mx.zeros((k, p.shape[-1]), dtype=p.dtype)
                    q = mx.put_along_axis(q, q_ids.astype(mx.int32), q_probs.astype(p.dtype), axis=-1)
                rows = mx.arange(k)
                ratio = p[rows, draft_ids] / mx.maximum(q[rows, draft_ids], 1e-20)
                n_ok = mx.sum(mx.cumprod((mx.random.uniform(shape=(k,)) < ratio).astype(mx.int32)))
                residual = mx.maximum(p[:k] - q, 0.0)
                mass = residual.sum(-1, keepdims=True)
                residual = mx.where(mass > 0, residual / mx.maximum(mass, 1e-20), p[:k])
                bonus = mx.random.categorical(mx.log(mx.concatenate([residual, p[k:]], axis=0)))
            if tree is None:
                logprobs = logprobs_of(logits)  # all rows at once, like the MTP loop
                mx.eval(n_ok, bonus, draft_ids, logprobs)
                j = int(n_ok.item())
                rollback = S._Rollback(target_cache, records, k + 1)
                out = draft_ids[:j].tolist() + [int(bonus[j].item())]
            if copy:
                copier.feedback(copy, j, time.perf_counter() - started)
            else:
                policy.update(k, j, time.perf_counter() - started)
            stats["rounds"] += 1
            stats["drafted"] += tree.L - 1 if tree is not None else k
            stats["accepted"] += j
            stats["tokens"] += j + 1
            if tree is not None:
                stats["tree_rounds"] = stats.get("tree_rounds", 0) + 1

            rollback.keep(j + 1)
            if copier:
                copier.observe(out)
            state.add(feats[:, : j + 1])
            z = mx.array([[out[-1]]], dtype=mx.uint32)

            def settle(i: int) -> None:
                """The consumer holds out[:i+1]; make the caches cover exactly that."""
                if i < j:
                    rollback.keep(i + 2)
                    state.drop(j - 1 - i)
                    mx.eval(state.pending, S._cache_arrays(target_cache))
                else:
                    feed(z)

            for i, t in enumerate(out):
                try:
                    yield t, logprobs[i], i < j
                except GeneratorExit:
                    settle(i)
                    return
                produced += 1
                if produced >= max_tokens:
                    settle(i)
                    return

        feed(z)
