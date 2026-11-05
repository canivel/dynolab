"""`dyno serve --model file.gguf`: a GGUF model on this Mac, run by llama.cpp's llama-server on the GPU (Metal).

llama-server listens on a private loopback port and Dyno's front end takes the public one, so a GGUF model gets what
an MLX model does: the Anthropic Messages and Responses APIs, web access and the browser, Observer history, /stats,
/metrics and the request lines in Performance → Logs. Generation requests are passed through as they stream and timed
here, from the chunks as they go by; llama-server's prompt progress becomes the "reading the prompt" lines.

The launch options the app passes are mlx_lm's; they are translated to llama-server's flags.
"""
from __future__ import annotations

import glob
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

from . import activity
from .exporters import PROMETHEUS_CONTENT_TYPE, prometheus_text, stats_json
from .metrics import MetricsRegistry
from ..apis import CodingAPIsMixin
from ..execution import ExecutionHTTPMixin, ExecutionStore

registry = MetricsRegistry()
# llama-server's --alias: the app leaves the process out of its model list, since the front end is the endpoint.
BACKEND = "dyno-backend"
_ALIAS = re.compile(rb'"model"\s*:\s*"' + BACKEND.encode() + rb'"')
# Without --ctx-size, a model whose own context is longer is given this much: a 256k-token context would hold tens
# of gigabytes of memory for the cache before the first request.
CONTEXT = 65536
GENERATION = ("/v1/chat/completions", "/chat/completions", "/v1/completions", "/completions")

# mlx_lm flag -> llama-server flag
FLAGS = {
    "--max-tokens": "--n-predict", "--temp": "--temp", "--top-p": "--top-p", "--top-k": "--top-k",
    "--decode-concurrency": "--parallel", "--chat-template-args": "--chat-template-kwargs", "--ctx-size": "--ctx-size",
}
IGNORED = {"--log-level", "--prompt-cache-size", "--prompt-concurrency", "--num-draft-tokens", "--draft-model"}


def is_gguf(argv: list[str]) -> bool:
    return (_value(argv, "--model") or "").lower().endswith(".gguf")


def _value(argv: list[str], name: str) -> Optional[str]:
    for index, argument in enumerate(argv):
        if argument == name and index + 1 < len(argv): return argv[index + 1]
        if argument.startswith(name + "="): return argument.split("=", 1)[1]
    return None


def find_llama_server() -> Optional[str]:
    """The app's own llama.cpp build first (the app passes it in DYNO_LLAMA_SERVER), then any other on this Mac."""
    home = Path.home()
    candidates = [os.environ.get("DYNO_LLAMA_SERVER"), "/Applications/Dyno.app/Contents/Resources/pool-runtime/llama-server",
                  *sorted(glob.glob(str(home / ".mlx-dyno/runtimes/llama-*/llama-server")), reverse=True), shutil.which("llama-server")]
    return next((c for c in candidates if c and os.path.isfile(c) and os.access(c, os.X_OK)), None)


def metadata(path: str, wanted: tuple[str, ...] = ("general.architecture", "general.name")) -> dict[str, Any]:
    """Header values from a GGUF file: the architecture, the name and the context length the model was trained for.
    Reads until those are found, which comes before the tokenizer's long arrays in files llama.cpp writes."""
    found: dict[str, Any] = {}
    sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
    formats = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}
    with open(path, "rb") as file:
        def read(count):
            data = file.read(count)
            if len(data) < count: raise ValueError("truncated GGUF header")
            return data

        def string():
            return read(struct.unpack("<Q", read(8))[0]).decode("utf-8", "replace")

        def value(kind):
            if kind == 8: return string()
            if kind == 9:
                inner, count = struct.unpack("<IQ", read(12))
                if inner in sizes: file.seek(sizes[inner] * count, 1); return None
                for _ in range(count): value(inner)
                return None
            if kind not in formats: raise ValueError(f"unknown GGUF value type {kind}")
            return struct.unpack(formats[kind], read(sizes[kind]))[0]

        if read(4) != b"GGUF": raise ValueError("not a GGUF file")
        version, _, count = struct.unpack("<IQQ", read(20))
        if version < 2: raise ValueError(f"GGUF version {version} is too old")
        for _ in range(count):
            key = string()
            item = value(struct.unpack("<I", read(4))[0])
            if key in wanted or key.endswith(".context_length"): found[key] = item
            arch = found.get("general.architecture")
            if all(k in found for k in wanted) and arch and f"{arch}.context_length" in found: break
    arch = found.get("general.architecture")
    return {"architecture": arch, "name": found.get("general.name"), "context_length": found.get(f"{arch}.context_length")}


def llama_arguments(argv: list[str]) -> tuple[str, int, str, list[str]]:
    """(host, port, model path, llama-server's flags) from `dyno serve`'s mlx_lm-style ones."""
    host, port, model, flags = "127.0.0.1", 8080, "", []
    values = iter(argv)
    given = set()
    for argument in values:
        name, equals, inline = argument.partition("=")
        if name == "--trust-remote-code": continue
        if not name.startswith("--"): raise SystemExit(f"Unexpected argument {argument!r}")
        value = inline if equals else next(values, "")
        if name == "--model": model = value
        elif name == "--host": host = value
        elif name == "--port": port = int(value)
        elif name in FLAGS: flags += [FLAGS[name], value]; given.add(name)
        elif name in IGNORED:
            if name == "--draft-model": print("Speculative decoding: a draft model isn't used with GGUF models.", flush=True)
        else: raise SystemExit(f"{name} isn't available for GGUF models.")
    if "--decode-concurrency" not in given: flags += ["--parallel", "1"]
    if "--ctx-size" not in given:
        try: trained = metadata(model).get("context_length")
        except (OSError, ValueError, struct.error): trained = None
        if not isinstance(trained, int) or trained > CONTEXT: flags += ["--ctx-size", str(CONTEXT)]
    # Every request sees the whole context, however many run at once; the GPU takes every layer.
    return host, port, model, ["--kv-unified", "--n-gpu-layers", "999", "--jinja", "--no-webui", *flags]


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Backend:
    """llama-server, run through a guard process that stops it when this process goes, however it goes."""

    def __init__(self, binary: str, model: str, flags: list[str]):
        self.port = _free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.lines: deque[str] = deque(maxlen=60)
        command = [binary, "--model", model, "--host", "127.0.0.1", "--port", str(self.port), "--alias", BACKEND, *flags]
        self.process = subprocess.Popen([sys.executable, "-m", "dyno.serve.gguf", "--guard", str(os.getpid()), *command],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for raw in self.process.stdout:
            line = raw.decode("utf-8", "replace").rstrip()
            if not line: continue
            self.lines.append(line)
            lower = line.lower()
            if "error" in lower or "failed" in lower or "out of memory" in lower: print(f"llama.cpp: {line}", flush=True)

    def wait_ready(self) -> Optional[str]:
        """None once the model is loaded, else why it couldn't load."""
        while True:
            if self.process.poll() is not None:
                reason = next((l for l in reversed(self.lines) if "error" in l.lower() or "failed" in l.lower()), None)
                return reason or (self.lines[-1] if self.lines else f"llama-server exited with status {self.process.returncode}")
            try:
                with urllib.request.urlopen(self.url + "/health", timeout=2) as response:
                    if response.status == 200: return None
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(0.25)

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=2.5)
            except subprocess.TimeoutExpired: self.process.kill()


def guard(parent: int, command: list[str]) -> int:
    """Runs llama-server and stops it when `parent` exits: macOS has no parent-death signal, and a model left running
    holds gigabytes of memory."""
    child = subprocess.Popen(command)

    def stop(*_):
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired: child.kill()
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while child.poll() is None:
        if os.getppid() != parent: stop()
        time.sleep(0.5)
    return child.returncode


class BackendHandler(BaseHTTPRequestHandler):
    """Dyno's endpoints, and everything else forwarded to llama-server; generation requests are timed."""

    backend = ""
    model_path = ""

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/health": return self._send(json.dumps({"status": "ok"}), "application/json")
        if path == "/metrics": return self._send(prometheus_text(registry), PROMETHEUS_CONTENT_TYPE)
        if path in ("/stats", "/v1/stats"): return self._send(stats_json(registry, model_path=self.model_path), "application/json")
        if path == "/lab/capabilities":
            return self._send(json.dumps(dict(serving_activations=False, model=self.model_path, max_input_tokens=0, max_layers=0)), "application/json")
        if path in ("/v1/models", "/models"):
            return self._send(json.dumps({"object": "list", "data": [
                {"id": self.model_path, "object": "model", "created": int(registry.model_loaded_at or time.time()), "owned_by": "llama.cpp"}]}),
                "application/json")
        self._forward(None)

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        self._forward(self.rfile.read(size) if size > 0 else b"")

    def _send(self, body: str, content_type: str, status: int = 200) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _forward(self, body: Optional[bytes]) -> None:
        path = self.path.split("?", 1)[0].rstrip("/")
        timed = body is not None and path in GENERATION
        progress, request = False, None
        if timed:
            try: request = json.loads(body)
            except ValueError: pass
            if isinstance(request, dict) and request.get("stream") and "return_progress" not in request:
                request["return_progress"] = progress = True  # llama-server reports how far it has read the prompt
                body = json.dumps(request).encode()
        headers = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "accept", "authorization")}
        upstream = urllib.request.Request(self.backend + self.path, data=body, headers=headers, method="POST" if body is not None else "GET")
        record = Timing(self.model_path) if timed else None
        # llama-server names its model by --alias; the client gets back the name it asked for.
        name = json.dumps(str(request.get("model") or "default_model") if isinstance(request, dict) else "default_model").encode()
        rename = lambda data: _ALIAS.sub(b'"model":' + name.replace(b"\\", b"\\\\"), data)
        try:
            response = urllib.request.urlopen(upstream, timeout=3600)
        except urllib.error.HTTPError as error:
            detail = error.read()
            if record: record.done("error", failed=True, error=f"llama-server answered {error.code}")
            self.send_response(error.code)
            self.send_header("Content-Type", error.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(detail)))
            self.end_headers()
            return self.wfile.write(detail)
        except (urllib.error.URLError, OSError) as error:
            if record: record.done("error", failed=True, error=str(error))
            return self._send(json.dumps({"error": {"type": "api_error", "message": f"llama-server could not be reached: {error}"}}),
                              "application/json", 502)
        with response:
            kind = response.headers.get("Content-Type", "application/json")
            self.send_response(response.status)
            self.send_header("Content-Type", kind)
            if "text/event-stream" in kind:
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return self._relay(response, record, progress, rename)
            data = rename(response.read())
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            if record:
                try: record.answer(json.loads(data))
                except ValueError: record.done("error", failed=True)

    def _relay(self, response: Any, record: Optional["Timing"], progress: bool, rename: Any) -> None:
        reason, skipping = None, False
        try:
            for raw in response:
                if skipping and raw.strip() == b"":
                    skipping = False; continue  # the blank line ending a chunk the client doesn't get
                if record and raw.startswith(b"data:") and raw[5:].strip() not in (b"", b"[DONE]"):
                    try: chunk = json.loads(raw[5:])
                    except ValueError: chunk = None
                    if isinstance(chunk, dict):
                        reason = record.chunk(chunk) or reason
                        if progress and "prompt_progress" in chunk:
                            skipping = True; continue  # asked for here, not by the client
                self.wfile.write(rename(raw))
                if raw in (b"\n", b"\r\n"): self.wfile.flush()
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            reason = "cancelled"  # closing the connection to llama-server stops the generation
        except (OSError, ValueError) as error:
            if record: record.done("error", failed=True, error=str(error))
            return
        if record: record.done(reason)

    def log_message(self, format: str, *args: Any) -> None:
        pass


class GGUFHandler(CodingAPIsMixin, ExecutionHTTPMixin, BackendHandler):
    execution_store = ExecutionStore()


class Timing:
    """One generation request in the registry and the activity log, from the stream llama-server sends."""

    def __init__(self, model: str):
        self.record = registry.begin_request(model)
        self.finished = False
        activity.watch(registry)
        activity.received(self.record)

    def _start(self, at: Optional[float] = None) -> None:
        if self.record.started_at is None:
            registry.note_started(self.record)
            if at is not None: self.record.started_at = at
            activity.started(self.record, self.record.queue_seconds)

    def chunk(self, chunk: dict) -> Optional[str]:
        reading = chunk.get("prompt_progress")
        if isinstance(reading, dict):
            total, cached, processed = (int(reading.get(k) or 0) for k in ("total", "cache", "processed"))
            first = self.record.started_at is None
            registry.note_usage(self.record, prompt_tokens=total, cached_tokens=cached)
            self._start()
            registry.note_read_absolute(self.record, max(processed - cached, 0), max(total - cached, 0))
            if first: activity.reading(self.record)
        reason = None
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            if any(delta.get(k) for k in ("content", "reasoning_content", "tool_calls")):
                self._start()
                first = self.record.first_token_at is None
                registry.note_token(self.record)
                if first: activity.first_token(self.record)
            reason = choice.get("finish_reason") or reason
        self._timings(chunk)
        return reason

    def _timings(self, payload: dict) -> None:
        timings = payload.get("timings")
        if isinstance(timings, dict) and timings.get("predicted_n") is not None:
            cached = int(timings.get("cache_n") or 0)
            registry.note_usage(self.record, prompt_tokens=int(timings.get("prompt_n") or 0) + cached, cached_tokens=cached)
            self.record.completion_tokens = int(timings["predicted_n"])

    def answer(self, payload: dict) -> None:
        """A whole (non-streamed) answer: llama-server's timings say when its first token came."""
        self._timings(payload)
        self._start(at=self.record.submitted_at)  # when llama-server picked it up isn't known: count no wait
        timings = payload.get("timings") or {}
        if self.record.first_token_at is None and timings.get("prompt_ms") is not None:
            self.record.first_token_at = self.record.submitted_at + float(timings["prompt_ms"]) / 1000
        reason = next((c.get("finish_reason") for c in payload.get("choices") or [] if c.get("finish_reason")), None)
        self.done(reason)

    def done(self, reason: Optional[str], failed: bool = False, error: Optional[str] = None) -> None:
        if self.finished: return
        self.finished = True
        registry.finish_request(self.record, finish_reason=reason, failed=failed)
        activity.finished(self.record, error)


def main(argv: list[str], options: dict[str, Any], banner: str) -> int:
    try: host, port, model, flags = llama_arguments(argv)
    except ValueError as error: print(f"Could not read the launch options: {error}", file=sys.stderr); return 1
    if not os.path.isfile(model):
        print(f"Could not load the model: {model} doesn't exist.", file=sys.stderr, flush=True); return 1
    binary = find_llama_server()
    if binary is None:
        print("Could not load the model: llama.cpp's llama-server wasn't found. Reinstall Dyno, or install llama.cpp "
              "(brew install llama.cpp).", file=sys.stderr, flush=True)
        return 1
    print(banner.format(host=host, port=port), flush=True)
    print(f"GGUF: served by llama.cpp on the GPU ({binary}).", flush=True)
    if options["use"] == "serve":
        registry.mode = "serve"
        ExecutionHTTPMixin.execution_history = False
        print("Mode: serve only (no Observer history).", flush=True)
    if options["web"]:
        CodingAPIsMixin.web_access = True
        print("Web access: on (chat requests without tools can search the web and read public pages).", flush=True)

    started = time.perf_counter()
    backend = Backend(binary, model, flags)
    signal.signal(signal.SIGTERM, lambda *_: (backend.stop(), os._exit(0)))
    try:
        problem = backend.wait_ready()
        if problem:
            print(f"Could not load the model: {problem[:300]}", file=sys.stderr, flush=True)
            return 1
        registry.note_model_loaded(name=model, load_seconds=time.perf_counter() - started)
        registry.tool_calls = "own"
        GGUFHandler.backend, GGUFHandler.model_path = backend.url, model
        server = ThreadingHTTPServer((host, port), GGUFHandler)
        server.daemon_threads = True
        print(f"Loaded {Path(model).name} in {time.perf_counter() - started:.1f} s.", flush=True)
        threading.Thread(target=_exit_with, args=(backend,), daemon=True).start()
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        backend.stop()
    return 0


def _exit_with(backend: Backend) -> None:
    """llama-server stopped on its own (a crash, say): stop too, so the app shows the model as stopped."""
    backend.process.wait()
    print(f"llama-server stopped: {backend.lines[-1] if backend.lines else backend.process.returncode}", file=sys.stderr, flush=True)
    os._exit(1)


if __name__ == "__main__" and sys.argv[1:2] == ["--guard"]:
    raise SystemExit(guard(int(sys.argv[2]), sys.argv[3:]))
