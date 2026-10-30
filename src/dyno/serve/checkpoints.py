"""Prompt-cache checkpoints for the single-stream path, so a conversation doesn't re-read its whole prompt every turn.

mlx_lm's single-stream path (one request at a time: `--decode-concurrency 1`, and every request with a drafter) saves
one prompt-cache entry per request: the prompt plus the reply as the model generated it. The next turn sends that
reply back as history, rendered by the chat template, and the tokens rarely match what was generated (thinking is
left out, tool calls are re-serialized). A plain KV cache would be trimmed back to the shared prefix, but Qwen3.5+
(Gated DeltaNet) layers carry a recurrent state that can't be trimmed, so the whole entry is useless: Claude Code's
12,000-token prompt was read again on every turn (21 s each on an M5 Max).

The batched path already saves the cache at the end of the system prompt and of the last user message. This does the
same for the single-stream path: before generating, it runs the prompt up to each turn boundary (a ChatML
`<|im_start|>`) and saves a copy of the cache there.
- After the system prompt and tools: a new session in any folder starts from it.
- At the start of the reply: the next turn's prompt begins with exactly these tokens, whatever the reply re-renders to.
The drafter (MTP or DFlash2) is run in lockstep, so speculative decoding continues from a checkpoint unchanged.
"""
from __future__ import annotations

import copy
import logging
import threading
from typing import Any, List, Optional

MIN_SEGMENT = 512  # tokens: shorter stretches cost more to copy than to read again

from . import progress

_log = logging.getLogger(__name__)
_pending = threading.local()


def marks(tokens: List[int], start_id: Optional[int]) -> List[int]:
    """Where to save: the start of the first turn after the system prompt, and the start of the last turn."""
    if start_id is None: return []
    starts = [i for i, t in enumerate(tokens) if t == start_id]
    if len(starts) < 2: return []
    return sorted({starts[1], starts[-1]})


def _start_id(tokenizer: Any) -> Optional[int]:
    try:
        ids = tokenizer.encode('<|im_start|>', add_special_tokens=False)
    except Exception:  # noqa: BLE001
        return None
    return ids[0] if len(ids) == 1 else None


def _prefill(model, draft_model, cache, tokens, step):
    import mlx.core as mx
    from mlx_lm.generate import generate_step

    prompt = mx.array(tokens)
    if draft_model is None:
        for _ in generate_step(prompt, model, max_tokens=0, prompt_cache=cache, prefill_step_size=step,
                               prompt_progress_callback=progress.counting(None)): pass
        return True
    if getattr(draft_model, 'is_dflash_drafter', False):
        from .dflash_spec import dflash_prefill
        dflash_prefill(prompt, model, draft_model, cache, step)
        return True
    if getattr(draft_model, 'is_mtp_drafter', False):
        from .speculative import mtp_prefill
        mtp_prefill(prompt, model, draft_model, cache, step)
        return True
    return False  # an mlx_lm draft model: its cache follows its own rules


def install(server_module: Any) -> None:
    """Save checkpoints in every single-stream request. Idempotent."""
    if getattr(server_module, '_dyno_checkpoints', False): return
    lru = server_module.LRUPromptCache
    fetch = lru.fetch_nearest_cache

    def fetch_nearest_cache(self, model, tokens):
        cache, rest = fetch(self, model, tokens)
        _pending.request = (self, model, list(tokens))
        return cache, rest

    lru.fetch_nearest_cache = fetch_nearest_cache
    original = server_module.stream_generate

    def stream_generate(model, tokenizer, prompt, *args, prompt_cache=None, draft_model=None, prefill_step_size=2048, **kwargs):
        request = getattr(_pending, 'request', None)
        _pending.request = None
        if isinstance(prompt, list):
            progress.begin(len(prompt), len(request[2]) - len(prompt) if request is not None else 0)
        # The plain loop reports through mlx_lm's callback; the MTP and DFlash2 loops report to `progress` directly.
        kwargs['prompt_progress_callback'] = progress.counting(kwargs.get('prompt_progress_callback'))
        if request is not None and prompt_cache is not None and isinstance(prompt, list) and prompt:
            try: prompt = _checkpoint(request, model, tokenizer, prompt, prompt_cache, draft_model, prefill_step_size)
            except Exception as error:  # noqa: BLE001 - a checkpoint is an optimization; never fail the request over it
                _log.warning('Prompt checkpoint skipped: %s', error)
        yield from original(model, tokenizer, prompt, *args, prompt_cache=prompt_cache, draft_model=draft_model,
                            prefill_step_size=prefill_step_size, **kwargs)

    server_module.stream_generate = stream_generate
    server_module._dyno_checkpoints = True


def _checkpoint(request, model, tokenizer, rest, cache, draft_model, step):
    """Prefill up to each boundary, save a copy of the cache there, and return what is left to read."""
    store, key, full = request
    done = len(full) - len(rest)
    if full[done:] != rest: return rest  # not the request the cache lookup saw
    from mlx_lm.generate import generation_stream, wired_limit

    for i, mark in enumerate(marks(full, _start_id(tokenizer))):
        if mark - done < MIN_SEGMENT or mark >= len(full): continue
        with wired_limit(model, [generation_stream]):
            if not _prefill(model, draft_model, cache, full[done:mark], step): return full[done:]
        done = mark
        store.insert_cache(key, full[:mark], copy.deepcopy(cache), cache_type='system' if i == 0 else 'user')
    return full[done:]
