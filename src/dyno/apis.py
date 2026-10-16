"""The coding tools' APIs on a Dyno server: Anthropic Messages (Claude Code) and OpenAI Responses (Codex).

Each request is translated to /v1/chat/completions on this same server and the answer translated back, so it goes
through everything chat completions already does: Dyno's tool-call parsing, the execution history the Observer
reads, metrics.

Web search: both tools ask for a search that runs on Anthropic's or OpenAI's servers. Here Dyno runs it: the model
gets a web_search function, Dyno answers its calls with Dyno's web search (SearXNG, or the paid provider chosen in
Settings) and lets the model continue, and the client sees the searches as server tool blocks or web_search_call items.

Only clients on this Mac are answered, and never from a web page (a browser sends Origin), so a site can't drive
the local model through them.
"""
from __future__ import annotations

import ipaddress
import json
import os
import queue
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import anthropic, responses
from .anthropic import RequestError

MAX_BODY = 32_000_000
# Seconds of silence before a keepalive: reading Claude Code's ~20k-token prompt takes minutes on some Macs.
KEEPALIVE = 10
PATHS = ('/v1/messages', '/v1/messages/count_tokens', '/v1/responses')


def _openai_error(kind, message):
    return {'error': {'type': kind, 'message': message, 'code': None, 'param': None}}


def wants_search(body, claude):
    """The client's hosted web search tool, when it asks for one: (how many searches, its settings)."""
    for tool in (body.get('tools') or []) if isinstance(body, dict) else []:
        kind = str(tool.get('type') or '') if isinstance(tool, dict) else ''
        if claude and kind.startswith('web_search_'): return max(1, min(int(tool.get('max_uses') or 5), 10)), tool
        if not claude and kind in ('web_search', 'web_search_preview'): return 5, tool
    return 0, None


def _host_in(url, domains):
    host = urllib.parse.urlsplit(url).hostname or ''
    return any(host == d or host.endswith('.' + d) for d in domains)


def filter_domains(results, tool):
    """Anthropic's allowed_domains / blocked_domains, and the Responses API's filters.allowed_domains."""
    tool = tool or {}
    allowed = [str(d).lower().lstrip('.') for d in tool.get('allowed_domains') or (tool.get('filters') or {}).get('allowed_domains') or []]
    blocked = [str(d).lower().lstrip('.') for d in tool.get('blocked_domains') or []]
    return [r for r in results if (not allowed or _host_in(r['url'], allowed)) and not _host_in(r['url'], blocked)]


def search_tool(name):
    return {'type': 'function', 'function': {
        'name': name, 'description': 'Search the web. Returns the titles, links and excerpts of matching pages.',
        'parameters': {'type': 'object', 'properties': {'query': {'type': 'string', 'description': 'What to search for'}}, 'required': ['query']}}}


_web, _web_lock = None, threading.Lock()


def web():
    """Dyno's web search, configured in the lab's data folder (the provider and SearXNG's settings)."""
    global _web
    with _web_lock:
        if _web is None:
            from .lab.websearch import WebSearch
            _web = WebSearch(Path(os.environ.get('DYNO_LAB_DATA') or '~/.mlx-dyno/lab').expanduser())
        return _web


def run_search(query, tool=None):
    """(results, error, text for the model)."""
    try:
        engine = web()
        if not engine.ready(wait=180): raise ValueError("Dyno's web search did not start. Check Docker, or choose a search provider in Settings.")
        found = engine.search(query, 10)
        found['results'] = filter_domains(found['results'], tool)[:6]
        if not found['results']: found['note'] = 'No results. Try other words.'
        return found['results'], None, json.dumps(found, ensure_ascii=False)
    except Exception as error:
        return [], str(error), f'Web search failed: {error}'


def _chunks(response):
    for line in response:
        line = line.strip()
        if not line.startswith(b'data:'): continue
        value = line[5:].strip()
        if value == b'[DONE]': return
        try: yield json.loads(value)
        except ValueError: continue


class CodingAPIsMixin:
    """POST /v1/messages, /v1/messages/count_tokens and /v1/responses. Use before the handler that serves chat completions."""

    def _api_reply(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _api_local(self):
        address = ipaddress.ip_address(self.client_address[0])
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped: address = address.ipv4_mapped
        return address.is_loopback and not self.headers.get('Origin')

    def _api_upstream(self):
        host, port = self.server.server_address[:2]
        if host in ('', '0.0.0.0', '::') or not ipaddress.ip_address(host).is_loopback: host = '127.0.0.1'
        return f"http://{'[%s]' % host if ':' in host else host}:{port}"

    def _api_model(self, requested):
        """The served model when the client names one this server doesn't list (Claude Code asks for claude-*)."""
        try:
            with urllib.request.urlopen(self._api_upstream() + '/v1/models', timeout=10) as r:
                listed = {m.get('id') for m in json.loads(r.read()).get('data') or []}
        except (urllib.error.URLError, OSError, ValueError):
            listed = set()
        return requested if requested in listed else 'default_model'

    def do_POST(self):
        path = self.path.split('?', 1)[0].rstrip('/')
        if path not in PATHS: return super().do_POST()
        claude = path.startswith('/v1/messages')
        fail = anthropic.error if claude else _openai_error
        if not self._api_local():
            return self._api_reply(fail('permission_error', 'This API is available only to programs on this Mac'), 403)
        try:
            size = int(self.headers.get('Content-Length') or 0)
            if not 0 < size <= MAX_BODY: raise RequestError('The request body is empty or too large')
            body = json.loads(self.rfile.read(size))
            if path.endswith('/count_tokens'): return self._api_reply(anthropic.count_tokens(body))
            requested = str(body.get('model') or 'default_model') if isinstance(body, dict) else ''
            translate = anthropic.to_openai if claude else responses.to_chat
            request = translate(body, self._api_model(requested))
            searches, hosted = wants_search(body, claude)
        except (RequestError, ValueError, UnicodeDecodeError) as e:
            return self._api_reply(fail('invalid_request_error', str(e)), 400)
        if searches:
            try: return self._api_with_search(request, requested, claude, searches, hosted)
            except (BrokenPipeError, ConnectionResetError): self.close_connection = True; return
        if request['stream']: return self._api_stream(request, requested, claude)
        upstream = urllib.request.Request(self._api_upstream() + '/v1/chat/completions', data=json.dumps(request).encode(),
                                          headers={'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(upstream, timeout=3600)
        except urllib.error.HTTPError as e:
            detail = e.read().decode('utf-8', 'replace')[:2000]
            return self._api_reply(fail('api_error', f'The model server answered {e.code}: {detail}'), 500 if e.code >= 500 else 400)
        except (urllib.error.URLError, OSError) as e:
            return self._api_reply(fail('api_error', f'The model server could not be reached: {e}'), 502)
        with response:
            result = json.loads(response.read())
        return self._api_reply(anthropic.from_openai(result, requested) if claude else responses.from_chat(result, requested))

    def _api_relay(self, request):
        """The model server's stream, read on a thread: ('chunk', payload) ... ('end', None), or ('http', (code, detail))
        or ('error', exception); ('idle', None) after KEEPALIVE seconds without a chunk."""
        items = queue.Queue()
        leaving = threading.Event()
        upstream = urllib.request.Request(self._api_upstream() + '/v1/chat/completions', data=json.dumps(request).encode(),
                                          headers={'Content-Type': 'application/json'})

        def pump():
            try:
                with urllib.request.urlopen(upstream, timeout=3600) as response:
                    for payload in _chunks(response):
                        if leaving.is_set(): return  # the client left: closing the connection stops the generation
                        items.put(('chunk', payload))
                items.put(('end', None))
            except urllib.error.HTTPError as e:
                items.put(('http', (e.code, e.read().decode('utf-8', 'replace')[:2000])))
            except (urllib.error.URLError, OSError, ValueError) as e:
                items.put(('error', e))

        threading.Thread(target=pump, daemon=True).start()
        try:
            while True:
                try: kind, value = items.get(timeout=KEEPALIVE)
                except queue.Empty: yield 'idle', None; continue
                yield kind, value
                if kind != 'chunk': return
        finally:
            leaving.set()

    def _api_stream(self, request, requested, claude):
        """Translate the stream; keepalives while the model reads the prompt. Errors before anything was sent keep their
        HTTP status."""
        fail = anthropic.error if claude else _openai_error
        stream = anthropic.StreamTranslator(requested) if claude else responses.StreamTranslator(requested)
        sent = False

        def write(data):
            nonlocal sent
            if not sent: self._api_stream_headers(); sent = True
            if data: self.wfile.write(data); self.wfile.flush()

        def failed(message):
            write(stream.event('error', anthropic.error('api_error', message)) if claude else stream.failed(message))

        try:
            for kind, value in self._api_relay(request):
                if kind == 'idle': write(stream.keepalive())
                elif kind == 'http':
                    code, detail = value
                    message = f'The model server answered {code}: {detail}'
                    if sent: return failed(message)
                    return self._api_reply(fail('api_error', message), 500 if code >= 500 else 400)
                elif kind == 'error':
                    message = f'The model server could not be reached: {value}'
                    if sent: return failed(message)
                    return self._api_reply(fail('api_error', message), 502)
                elif kind == 'chunk':
                    if value.get('error'): return failed(json.dumps(value['error'])[:2000])
                    if (out := stream.chunk(value)): write(out)
            write(stream.finish() if claude else stream.done())
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # the client gave up; the model server stops when its stream is closed

    def _api_stream_headers(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.close_connection = True
        self.end_headers()

    def _api_with_search(self, request, requested, claude, limit, hosted=None):
        """Rounds of generation; between them Dyno runs the searches the model asked for."""
        fail = anthropic.error if claude else _openai_error
        names = {t['function']['name'] for t in request.get('tools') or []}
        name = 'web_search' if 'web_search' not in names else 'dyno_web_search'
        tools = [*(request.get('tools') or []), search_tool(name)]
        streaming = request['stream']
        request.update(stream=True, stream_options={'include_usage': True})
        stream = (anthropic.StreamTranslator if claude else responses.StreamTranslator)(requested, hidden={name})
        kept = bytearray()

        def send(data):
            if not data: return
            if streaming: self.wfile.write(data); self.wfile.flush()
            else: kept.extend(data)

        if streaming: self._api_stream_headers()
        for round_ in range(limit + 1):
            # The last round has no search tool, so the model answers with what it found.
            request['tools'] = tools if round_ < limit else tools[:-1]
            if not request['tools']: request.pop('tools'); request.pop('tool_choice', None)
            error = None
            for kind, value in self._api_relay(request):
                if kind == 'idle':
                    if streaming: send(stream.keepalive())
                elif kind == 'chunk':
                    if value.get('error'): error = json.dumps(value['error'])[:2000]; break
                    send(stream.chunk(value))
                elif kind == 'http': error = f'{value[0]}: {value[1]}'
                elif kind == 'error': error = str(value)
            if error:
                message = f'The model server failed: {error}'
                if not streaming: return self._api_reply(fail('api_error', message), 502)
                return send(stream.event('error', anthropic.error('api_error', message)) if claude else stream.failed(message))
            calls = stream.hidden_calls()
            if not calls: break
            answers = []
            for call in calls:
                query = str(anthropic._input(call['arguments']).get('query') or '')[:300]
                results, error, text = run_search(query, hosted)
                send(stream.searched(call, query, results, error))
                answers.append({'role': 'tool', 'tool_call_id': call['id'], 'content': text})
            request['messages'] = [*request['messages'], {'role': 'assistant', 'content': stream.text, 'tool_calls': [
                {'id': c['id'], 'type': 'function', 'function': {'name': c['name'], 'arguments': c['arguments'] or '{}'}} for c in calls]}, *answers]
            stream.new_round()
        send(stream.finish() if claude else stream.done())
        if not streaming:
            self._api_reply(anthropic.collect(bytes(kept)) if claude else responses.collect(bytes(kept)))
