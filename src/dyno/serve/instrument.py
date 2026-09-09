"""Instrumentation layered onto mlx_lm's server.

mlx_lm already does the hard parts -- batching, prompt caching, speculative
decoding -- and its generation loop computes throughput internally; it simply
never exposes it. Rather than reimplement any of that, these subclasses hook
the two seams that matter: the token stream (for timing) and the GET router
(for the endpoints).
"""

from __future__ import annotations

import json
import logging
from typing import Any

from mlx_lm.server import APIHandler, ResponseGenerator

from .exporters import PROMETHEUS_CONTENT_TYPE, prometheus_text, stats_json
from .metrics import MetricsRegistry
from ..execution import ExecutionHTTPMixin, ExecutionStore, current_execution

from .activations import CaptureBroker

registry = MetricsRegistry()


class InstrumentedResponseGenerator(ResponseGenerator):
    """Wraps the token stream so every request is timed at the source.

    Hooking here rather than in the HTTP handler means streaming and
    non-streaming requests are measured identically: both pull from this same
    generator, so time to first token is real in both cases.
    """

    def __init__(self, *args, **kwargs):
        self.activation_captures = CaptureBroker()
        super().__init__(*args, **kwargs)

    def _next_request(self, timeout=None):
        # This seam runs on mlx_lm's single generation thread, between scheduler
        # iterations. No HTTP thread touches layers; active batch caches are not used.
        if not self._is_distributed:
            self.activation_captures.service(self.model_provider)
        return super()._next_request(timeout)

    def generate(self, request, generation_args, progress_callback=None):
        model = _model_name(generation_args, request)
        record = registry.begin_request(model)
        execution = current_execution()
        if execution:
            execution.tokens = True
            execution.data["model"] = model
            execution.event("lifecycle", "Queued for generation")

        try:
            # This call blocks until the scheduler picks the request up, so
            # everything before it is queue wait.
            context, stream = super().generate(request, generation_args, progress_callback)
        except Exception:
            registry.finish_request(record, finish_reason="error", failed=True)
            raise

        registry.note_started(record)
        if execution:
            execution.event("lifecycle", "\nPrompt ready; generating")

        # The context carries the tokenized prompt and how much of it the
        # prompt cache satisfied, which is the only place those are exposed.
        prompt = getattr(context, "prompt", None)
        if prompt is not None:
            cached = getattr(context, "prompt_cache_count", -1)
            registry.note_usage(
                record,
                prompt_tokens=len(prompt),
                cached_tokens=cached if isinstance(cached, int) and cached > 0 else 0,
            )

        return context, self._timed(stream, record)

    def _timed(self, stream, record):
        finish_reason: str | None = None
        failed = False
        try:
            for token in stream:
                registry.note_token(record)
                execution = current_execution()
                if execution:
                    with execution.store.lock:
                        execution.data["output_tokens"] += 1
                    state = getattr(token, "state", "normal")
                    execution.event({"reasoning": "thinking", "tool": "tool"}.get(state, "output"), getattr(token, "text", ""))
                finish_reason = getattr(token, "finish_reason", None) or finish_reason
                yield token
        except GeneratorExit:
            # The client hung up mid-stream; still record what was produced.
            finish_reason = finish_reason or "cancelled"
            raise
        except Exception:
            failed = True
            finish_reason = "error"
            raise
        finally:
            registry.finish_request(record, finish_reason=finish_reason, failed=failed)
            execution = current_execution()
            if execution:
                execution.data["finish_reason"] = finish_reason
                if failed:
                    execution.event("error", "Generation failed")


def _model_name(generation_args: Any, request: Any) -> str:
    description = getattr(generation_args, "model", None)
    for candidate in (
        getattr(description, "model", None),
        getattr(request, "model", None),
        registry.model_name,
    ):
        if isinstance(candidate, str) and candidate:
            return candidate
    return "unknown"


class InstrumentedAPIHandler(ExecutionHTTPMixin, APIHandler):
    """Adds /metrics and /stats; everything else falls through to mlx_lm."""

    execution_store = ExecutionStore()

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/lab/capabilities":
            if not self._execution_local(): return
            provider = self.response_generator.model_provider
            key = provider.model_key
            self._execution_send(dict(serving_activations=not self.response_generator._is_distributed,
                model=str(key[0]) if key else None, max_input_tokens=256, max_layers=4))
        elif path == "/metrics":
            self._send(prometheus_text(registry), PROMETHEUS_CONTENT_TYPE)
        elif path in ("/stats", "/v1/stats"):
            self._send(stats_json(registry, model_path=self._model_path()), "application/json")
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/lab/activations":
            return super().do_POST()
        if not self._execution_local(): return
        try:
            if self.response_generator._is_distributed:
                raise ValueError("Serving activation capture is unavailable for distributed servers")
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 65536:
                raise ValueError("Capture body must be 1–65536 bytes")
            config = json.loads(self.rfile.read(size))
            result = self.response_generator.activation_captures.submit(config)
            self._execution_send(result)
        except TimeoutError as error:
            self._execution_send({"error": str(error)}, 408)
        except RuntimeError as error:
            self._execution_send({"error": str(error)}, 409)
        except Exception as error:
            self._execution_send({"error": str(error)}, 400)

    def _model_path(self) -> str | None:
        try:
            return getattr(self.response_generator.cli_args, "model", None)
        except Exception:
            return None

    def _send(self, body: str, content_type: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self._set_cors_headers()
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def log_message(self, format: str, *args: Any) -> None:
        # mlx_lm's handler logs every request to stderr, which floods the
        # console once a monitor is polling /metrics. Route it to the logger so
        # --log-level controls it like everything else.
        logging.debug("%s - %s", self.address_string(), format % args)


def usage_from_response(payload: bytes) -> dict[str, int] | None:
    """Best-effort extraction of an OpenAI usage block, for tests."""
    try:
        return json.loads(payload).get("usage")
    except Exception:
        return None
