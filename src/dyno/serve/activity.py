"""What the server is doing, one readable line at a time, for the log and the app's Performance → Logs.

Each request gets a line when it arrives, when it starts reading its prompt, when the first token comes out and when
it ends. While it runs, a watcher adds a line every few seconds: how far it has read the prompt, how fast it is
generating, or that nothing has moved. A long first prompt on a slower Mac then reads as progress, not as a hang.
"""
from __future__ import annotations

import sys
import threading
import time
from typing import Any, Optional

READING_EVERY = 10.0     # seconds between progress lines while reading a prompt
GENERATING_EVERY = 30.0  # seconds between lines while generating
QUIET_AFTER = 30.0       # seconds without a new token before saying so

_lock = threading.Lock()
_watcher: Optional[threading.Thread] = None
_said: dict[int, float] = {}  # request id -> when the watcher last wrote about it


def say(text: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {text}", flush=True, file=sys.stdout)


def _n(value: Optional[float]) -> str:
    return "?" if value is None else f"{value:,.0f}"


def received(record: Any) -> None:
    say(f"request {record.request_id} · received")


def started(record: Any, waited: Optional[float]) -> None:
    tokens = f"{record.prompt_tokens:,} prompt tokens" if record.prompt_tokens else "prompt"
    after = f" after waiting {waited:.0f} s for the request before it" if waited and waited >= 1 else ""
    say(f"request {record.request_id} · started{after} · {tokens}")


def reading(record: Any) -> None:
    if record is None: return
    cached = f", {record.cached_prompt_tokens:,} from the prompt cache" if record.cached_prompt_tokens else ""
    say(f"request {record.request_id} · reading {record.prompt_to_read:,} new prompt tokens{cached}")
    _said[record.request_id] = time.perf_counter()


def first_token(record: Any) -> None:
    rate = record.prompt_read / (record.first_token_at - record.reading_started_at) \
        if record.prompt_read >= 512 and record.reading_started_at and record.first_token_at > record.reading_started_at else None
    speed = f" · read the prompt at {_n(rate)} tok/s" if rate else ""
    say(f"request {record.request_id} · first token after {record.time_to_first_token:.1f} s{speed}")
    _said[record.request_id] = time.perf_counter()


def finished(record: Any, error: Optional[str] = None) -> None:
    _said.pop(record.request_id, None)
    if record.failed:
        say(f"request {record.request_id} · failed after {record.total_seconds or 0:.1f} s" + (f": {error}" if error else ""))
        return
    rate = record.decode_tokens_per_second
    speed = f" ({rate:.1f} tok/s)" if rate else ""
    say(f"request {record.request_id} · {record.finish_reason or 'done'} · {record.completion_tokens:,} tokens"
        f"{speed} · {record.total_seconds or 0:.1f} s in all")


def watch(registry: Any) -> None:
    """Start the watcher once: a daemon thread that reports on unfinished requests."""
    global _watcher
    with _lock:
        if _watcher is not None: return
        _watcher = threading.Thread(target=_watch, args=(registry,), name="dyno-activity", daemon=True)
        _watcher.start()


def _watch(registry: Any) -> None:
    while True:
        time.sleep(1.0)
        try: report(registry, time.perf_counter())
        except Exception: pass  # noqa: BLE001 - the log must never take the server down


def report(registry: Any, now: float) -> None:
    for live in registry.live_requests():
        rid, phase = live["request_id"], live["phase"]
        last = _said.setdefault(rid, now)
        if phase == "reading" and now - last >= READING_EVERY:
            _said[rid] = now
            to_read, read = live["prompt_to_read"], live["prompt_read"]
            if not to_read:
                what = "loading the model" if registry.model_loaded_at is None else "preparing the prompt"
                say(f"request {rid} · {what} · {live['seconds']:.0f} s")
            else:
                rate = live["prompt_read_tokens_per_second"]
                left = f" · about {(to_read - read) / rate:.0f} s left" if rate and read < to_read else ""
                say(f"request {rid} · reading the prompt: {read:,} of {to_read:,} tokens ({100 * read // max(to_read, 1)}%)"
                    f" · {_n(rate)} tok/s{left} · {live['seconds']:.0f} s")
        elif phase == "generating":
            quiet = live["seconds_since_last_token"] or 0
            if quiet >= QUIET_AFTER and now - last >= QUIET_AFTER:
                _said[rid] = now
                say(f"request {rid} · no new token for {quiet:.0f} s ({live['completion_tokens']:,} so far)")
            elif quiet < QUIET_AFTER and now - last >= GENERATING_EVERY:
                _said[rid] = now
                rate = live["decode_tokens_per_second"]
                say(f"request {rid} · generating: {live['completion_tokens']:,} tokens"
                    + (f" · {rate:.1f} tok/s" if rate else "") + f" · {live['seconds']:.0f} s")
        elif phase == "queued" and now - last >= READING_EVERY:
            _said[rid] = now
            say(f"request {rid} · waiting for the request before it to finish · {live['seconds']:.0f} s")
