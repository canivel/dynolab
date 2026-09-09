"""Bounded, in-memory execution capture shared by the server and router.

Records only observable request data and model output, never hidden activations.
The HTTP adapter observes bytes without buffering or changing the response stream.
"""
from __future__ import annotations

import contextvars
import copy
import ipaddress
import json
import threading
import time
import uuid
from urllib.parse import urlsplit

_current = contextvars.ContextVar("dyno_execution", default=None)
LIMIT = 262_144


def current_execution():
    return _current.get()


class ExecutionStore:
    def __init__(self, capacity=64, text_limit=LIMIT):
        self.capacity, self.text_limit = capacity, text_limit
        self.lock = threading.RLock()
        self.records = {}
        self.dropped = 0

    def begin(self, endpoint, parent=None):
        with self.lock:
            if len(self.records) >= self.capacity:
                old = next((key for key, value in self.records.items()
                            if value.data["status"] != "running"), None)
                if old is None:
                    self.dropped += 1
                    return None
                del self.records[old]
            record = Execution(self, endpoint, parent)
            self.records[record.data["id"]] = record
            return record

    def snapshot(self, identifier=None):
        with self.lock:
            if identifier:
                record = self.records.get(identifier)
                return copy.deepcopy(record.data) if record else None
            return {"executions": [
                {k: copy.deepcopy(v) for k, v in record.data.items() if k not in ("input", "events")}
                for record in reversed(list(self.records.values()))
            ], "capacity": self.capacity, "text_limit": self.text_limit, "dropped": self.dropped}

    def clear(self):
        with self.lock:
            # Active requests keep their identities and remain observable.
            self.records = {k: v for k, v in self.records.items() if v.data["status"] == "running"}
            self.dropped = 0


class Execution:
    def __init__(self, store, endpoint, parent):
        self.store = store
        self.remaining = store.text_limit
        self.tokens = False
        self.data = dict(id=uuid.uuid4().hex, parent_id=parent, endpoint=endpoint,
                         started=time.time(), ended=None, status="running", model="pending",
                         thinking=None, stream=False, input="", events=[], truncated=False,
                         finish_reason=None, output_tokens=0, preview="")

    def bounded(self, text):
        value = text[:self.remaining]
        self.remaining -= len(value)
        if len(value) < len(text):
            self.data["truncated"] = True
        return value

    def request(self, raw, truncated=False):
        with self.store.lock:
            try:
                body = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                body = None
            self.data["input"] = self.bounded(json.dumps(body, ensure_ascii=False, indent=2)
                                               if body is not None else raw.decode("utf-8", "replace"))
            self.data["truncated"] |= truncated
            if isinstance(body, dict):
                self.data["model"] = str(body.get("model") or "default")[:512]
                self.data["stream"] = bool(body.get("stream"))
                kwargs = body.get("chat_template_kwargs")
                thinking = kwargs.get("enable_thinking") if isinstance(kwargs, dict) else None
                self.data["thinking"] = thinking if isinstance(thinking, bool) else None
                messages = body.get("messages") or []
                prompt = next((m.get("content", "") for m in reversed(messages)
                               if isinstance(m, dict) and m.get("role") == "user"), body.get("prompt", "")) if isinstance(messages, list) else ""
                self.data["preview"] = (prompt if isinstance(prompt, str) else json.dumps(prompt))[:180]

    def event(self, kind, text, choice=0):
        if not text:
            return
        with self.store.lock:
            text = self.bounded(str(text))
            if not text:
                return
            events = self.data["events"]
            now = time.time()
            if events and events[-1]["kind"] == kind and events[-1]["choice"] == choice:
                events[-1]["text"] += text
                events[-1]["updated"] = now
            elif len(events) < 1024:
                events.append(dict(id=len(events), kind=kind, text=text, time=now, updated=now, choice=choice))
            else:
                self.data["truncated"] = True

    def packet(self, payload):
        if not isinstance(payload, dict):
            return
        with self.store.lock:
            if payload.get("model"):
                self.data["model"] = str(payload["model"])[:512]
            if payload.get("error"):
                self.event("error", json.dumps(payload["error"], ensure_ascii=False))
            if isinstance(payload.get("usage"), dict):
                self.data["usage"] = {k: v for k, v in payload["usage"].items()
                                      if k in ("prompt_tokens", "completion_tokens", "total_tokens") and isinstance(v, int)}
            for choice in payload.get("choices") or []:
                if not isinstance(choice, dict):
                    continue
                if choice.get("finish_reason"):
                    self.data["finish_reason"] = str(choice["finish_reason"])[:80]
                if self.tokens:
                    continue
                delta = choice.get("delta") or choice.get("message") or {}
                if not isinstance(delta, dict):
                    continue
                index = choice.get("index", 0)
                if not isinstance(index, int):
                    index = 0
                for key in ("reasoning", "reasoning_content", "content"):
                    if isinstance(delta.get(key), str):
                        self.event("thinking" if key != "content" else "output", delta[key], index)
                if isinstance(choice.get("text"), str):
                    self.event("output", choice["text"], index)
                if delta.get("tool_calls"):
                    self.event("tool", json.dumps(delta["tool_calls"], ensure_ascii=False) + "\n", index)

    def finish(self, status):
        with self.store.lock:
            self.data["status"] = status
            self.data["ended"] = time.time()


class ResponseCapture:
    """Incremental SSE / JSON parser; partial UTF-8 is decoded only at frame boundaries."""
    def __init__(self, record):
        self.record = record
        self.buffer = b""
        self.sse = False
        self.overflow = False
        self.done = False

    def feed(self, data):
        if self.overflow:
            return
        self.buffer += data
        if len(self.buffer) > LIMIT * 2:
            self.record.data["truncated"] = True
            self.buffer = b""
            self.overflow = True
            return
        if self.sse:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                self.line(line)

    def line(self, line):
        if line.startswith(b"data:"):
            value = line[5:].strip()
            if value == b"[DONE]":
                self.done = True
            else:
                self.decode(value)

    def decode(self, value):
        try:
            self.record.packet(json.loads(value))
        except (ValueError, UnicodeDecodeError):
            pass

    def finish(self):
        if self.sse:
            self.line(self.buffer)
        elif self.buffer:
            self.decode(self.buffer)
        self.buffer = b""


class _Reader:
    def __init__(self, source, record):
        self.source, self.record = source, record
        self.captured = False

    def read(self, size=-1):
        value = self.source.read(size)
        if not self.captured:
            self.record.request(value[:LIMIT], len(value) > LIMIT)
            self.captured = True
        return value

    def __getattr__(self, name):
        return getattr(self.source, name)


class _Writer:
    def __init__(self, source, handler, capture):
        self.source, self.handler, self.capture = source, handler, capture

    def write(self, value):
        result = self.source.write(value)
        if self.handler._execution_headers_done:
            self.capture.feed(value)
        return result

    def __getattr__(self, name):
        return getattr(self.source, name)


class ExecutionHTTPMixin:
    """Use before the existing handler in its MRO; preserves inference transport."""
    execution_store: ExecutionStore

    def _execution_endpoint(self):
        return self.path.split("?", 1)[0].rstrip("/")

    def _execution_send(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _execution_local(self):
        address = ipaddress.ip_address(self.client_address[0])
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        host = urlsplit("//" + self.headers.get("Host", "")).hostname
        if not address.is_loopback or self.headers.get("Origin") or host not in ("localhost", "127.0.0.1", "::1"):
            self._execution_send({"error": "execution history is available only to local native clients"}, 403)
            return False
        return True

    def do_GET(self):
        path = self._execution_endpoint()
        if path == "/executions" or path.startswith("/executions/"):
            if not self._execution_local():
                return
            identifier = path[len("/executions/"):] if path.startswith("/executions/") else None
            result = self.execution_store.snapshot(identifier)
            self._execution_send(result if result is not None else {"error": "execution expired"}, 200 if result is not None else 404)
        else:
            super().do_GET()

    def do_DELETE(self):
        if self._execution_endpoint() != "/executions":
            self._execution_send({"error": "not found"}, 404)
        elif self._execution_local():
            self.execution_store.clear()
            self._execution_send({"cleared": True})

    def send_response(self, code, message=None):
        self._execution_status = code
        self._execution_headers_done = False
        super().send_response(code, message)

    def send_header(self, keyword, value):
        capture = getattr(self, "_execution_capture", None)
        if capture and keyword.lower() == "content-type":
            capture.sse = "text/event-stream" in value
        super().send_header(keyword, value)

    def end_headers(self):
        super().end_headers()
        self._execution_headers_done = True

    def do_POST(self):
        if self._execution_endpoint() not in ("/v1/chat/completions", "/v1/completions", "/chat/completions", "/completions"):
            return super().do_POST()
        record = self.execution_store.begin(self._execution_endpoint(), self.headers.get("X-Dyno-Execution-ID", "")[:64] or None)
        if record is None:
            return super().do_POST()
        original_reader, original_writer = self.rfile, self.wfile
        capture = ResponseCapture(record)
        self._execution_capture = capture
        self._execution_status = 200
        self._execution_headers_done = False
        self.rfile, self.wfile = _Reader(self.rfile, record), _Writer(self.wfile, self, capture)
        token = _current.set(record)
        status = "completed"
        try:
            super().do_POST()
            if self._execution_status >= 400 or record.data["finish_reason"] == "error":
                status = "failed"
            elif record.data["finish_reason"] == "cancelled" or (capture.sse and not capture.done):
                status = "cancelled"
        except (BrokenPipeError, ConnectionResetError):
            status = "cancelled"
            raise
        except Exception as error:
            status = "failed"
            record.event("error", str(error))
            raise
        finally:
            capture.finish()
            record.finish(status)
            _current.reset(token)
            self.rfile, self.wfile = original_reader, original_writer
            self._execution_capture = None
