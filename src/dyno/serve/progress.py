"""How far the model has read the current prompt.

The prefill loops (plain, MTP head, DFlash2 draft model, prompt-cache checkpoints) report each chunk they read here;
the metrics registry listens. mlx_lm's own `prompt_progress_callback` doesn't reach the speculative loops, so without
this a long first prompt looks the same as a stuck server.
"""
from __future__ import annotations

from typing import Callable, Optional

# Set by the server: begin(new_tokens, cached_tokens) when a request starts reading, advance(tokens) per chunk.
on_begin: Optional[Callable[[int, int], None]] = None
on_advance: Optional[Callable[[int], None]] = None


def begin(new_tokens: int, cached_tokens: int = 0) -> None:
    if on_begin is not None:
        try: on_begin(int(new_tokens), int(cached_tokens))
        except Exception: pass  # noqa: BLE001 - reporting must never break generation


def advance(tokens: int) -> None:
    if on_advance is not None and tokens > 0:
        try: on_advance(int(tokens))
        except Exception: pass  # noqa: BLE001


def counting(callback: Optional[Callable[[int, int], None]]) -> Callable[[int, int], None]:
    """Wrap mlx_lm's cumulative `prompt_progress_callback(processed, total)` so each step also advances the count."""
    last = [0]

    def report(processed: int, total: int) -> None:
        if processed < last[0]: last[0] = 0  # a new prefill
        advance(processed - last[0])
        last[0] = processed
        if callback is not None: callback(processed, total)

    return report
