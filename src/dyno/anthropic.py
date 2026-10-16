"""Anthropic Messages API on top of Dyno's OpenAI endpoint, so Claude Code and Anthropic SDKs can use a local model.

POST /v1/messages is translated to /v1/chat/completions on this same server, and the answer (or its stream)
is translated back. The request then goes through everything chat completions already does: Dyno's tool-call
parsing, the execution history the Observer reads, metrics. Standard library only.

Only clients on this Mac are answered, and never from a web page (a browser sends Origin), so a site
can't drive the local model through it.
"""
from __future__ import annotations

import ipaddress
import json
import urllib.error
import urllib.request
import uuid

PATHS = ('/v1/messages', '/v1/messages/count_tokens')
MAX_BODY = 32_000_000
STOP = {'stop': 'end_turn', 'length': 'max_tokens', 'tool_calls': 'tool_use', 'function_call': 'tool_use'}


class RequestError(ValueError):
    pass


def _text(content):
    """Text of a string or a list of content blocks; blocks that aren't text are left out."""
    if isinstance(content, str): return content
    if not isinstance(content, list): return ''
    return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')


def _image(block):
    source = block.get('source') or {}
    if source.get('type') == 'base64':
        return {'type': 'image_url', 'image_url': {'url': f"data:{source.get('media_type', 'image/png')};base64,{source.get('data', '')}"}}
    if source.get('type') == 'url':
        return {'type': 'image_url', 'image_url': {'url': source.get('url', '')}}
    return None


def _user(content):
    """One Anthropic user turn: tool results become tool messages, first, as OpenAI expects them right after the call."""
    if isinstance(content, str): return [{'role': 'user', 'content': content}]
    tools, parts = [], []
    for block in content or []:
        if not isinstance(block, dict): continue
        kind = block.get('type')
        if kind == 'tool_result':
            text = _text(block.get('content'))
            if block.get('is_error'): text = 'Error: ' + text
            tools.append({'role': 'tool', 'tool_call_id': str(block.get('tool_use_id', '')), 'content': text})
        elif kind == 'text':
            parts.append({'type': 'text', 'text': block.get('text', '')})
        elif kind == 'image' and (image := _image(block)):
            parts.append(image)
        elif kind == 'document' and (block.get('source') or {}).get('type') == 'text':
            parts.append({'type': 'text', 'text': block['source'].get('data', '')})
    out = list(tools)
    if parts:
        only_text = all(p['type'] == 'text' for p in parts)
        out.append({'role': 'user', 'content': '\n'.join(p['text'] for p in parts) if only_text else parts})
    return out


def _assistant(content):
    if isinstance(content, str): return [{'role': 'assistant', 'content': content}]
    text, calls = [], []
    for block in content or []:
        if not isinstance(block, dict): continue
        if block.get('type') == 'text':
            text.append(block.get('text', ''))
        elif block.get('type') == 'tool_use':
            calls.append({'id': str(block.get('id', '')), 'type': 'function',
                          'function': {'name': str(block.get('name', '')),
                                       'arguments': json.dumps(block.get('input') or {}, ensure_ascii=False)}})
        # Thinking blocks are the model's own earlier reasoning; chat templates drop it from history anyway.
    message = {'role': 'assistant', 'content': ''.join(text)}
    if calls: message['tool_calls'] = calls
    return [message]


def to_openai(body, model='default_model'):
    """An Anthropic Messages request as an OpenAI chat completions request."""
    if not isinstance(body, dict): raise RequestError('The request body must be a JSON object')
    messages = body.get('messages')
    if not isinstance(messages, list) or not messages: raise RequestError('messages: give at least one message')
    out = []
    system = _text(body.get('system'))
    if system: out.append({'role': 'system', 'content': system})
    for m in messages:
        if not isinstance(m, dict) or m.get('role') not in ('user', 'assistant', 'system'):
            raise RequestError('Each message has a role: user, assistant or system')
        if m['role'] == 'system':
            # Claude Code puts context in a system message mid-conversation. Many chat templates (Qwen's among them)
            # refuse a system message after the first, so it goes in as user text where it stands, which also
            # keeps the prompt cache's prefix stable.
            text = _text(m.get('content'))
            if not text: continue
            if out and out[-1]['role'] == 'user' and isinstance(out[-1]['content'], str): out[-1]['content'] += '\n\n' + text
            else: out.append({'role': 'user', 'content': text})
            continue
        out.extend(_user(m.get('content')) if m['role'] == 'user' else _assistant(m.get('content')))
    request = {'model': model, 'messages': out, 'stream': bool(body.get('stream'))}
    if isinstance(body.get('max_tokens'), int): request['max_tokens'] = body['max_tokens']
    for key in ('temperature', 'top_p', 'top_k'):
        if isinstance(body.get(key), (int, float)) and not isinstance(body.get(key), bool): request[key] = body[key]
    if isinstance(body.get('stop_sequences'), list) and body['stop_sequences']: request['stop'] = body['stop_sequences']
    # Server tools (web search, code execution...) run at Anthropic; only client tools have an input_schema.
    tools = [t for t in body.get('tools') or [] if isinstance(t, dict) and 'input_schema' in t]
    if tools:
        request['tools'] = [{'type': 'function', 'function': {'name': t.get('name', ''), 'description': t.get('description', ''),
                                                              'parameters': t.get('input_schema') or {'type': 'object'}}} for t in tools]
        choice = body.get('tool_choice') or {}
        kind = choice.get('type') if isinstance(choice, dict) else None
        if kind == 'any': request['tool_choice'] = 'required'
        elif kind == 'none': request['tool_choice'] = 'none'
        elif kind == 'tool': request['tool_choice'] = {'type': 'function', 'function': {'name': choice.get('name', '')}}
    thinking = body.get('thinking')  # 'adaptive' leaves it to how the server was started
    if isinstance(thinking, dict) and thinking.get('type') in ('enabled', 'disabled'):
        request['chat_template_kwargs'] = {'enable_thinking': thinking['type'] == 'enabled'}
    if request['stream']: request['stream_options'] = {'include_usage': True}
    return request


def _input(arguments):
    if isinstance(arguments, dict): return arguments
    try:
        value = json.loads(arguments or '{}')
    except (TypeError, ValueError):
        return {'_raw': arguments}
    return value if isinstance(value, dict) else {'value': value}


def _tool_id(value):
    return str(value) if value else 'toolu_' + uuid.uuid4().hex[:24]


def from_openai(response, model):
    """An OpenAI chat completion as an Anthropic message."""
    choice = (response.get('choices') or [{}])[0]
    message = choice.get('message') or {}
    content = []
    reasoning = message.get('reasoning') or message.get('reasoning_content')
    if reasoning: content.append({'type': 'thinking', 'thinking': reasoning, 'signature': ''})
    if message.get('content'): content.append({'type': 'text', 'text': message['content']})
    for call in message.get('tool_calls') or []:
        fn = call.get('function') or {}
        content.append({'type': 'tool_use', 'id': _tool_id(call.get('id')), 'name': fn.get('name', ''), 'input': _input(fn.get('arguments'))})
    usage = response.get('usage') or {}
    stop = 'tool_use' if message.get('tool_calls') else STOP.get(choice.get('finish_reason'), 'end_turn')
    return {'id': 'msg_' + uuid.uuid4().hex[:24], 'type': 'message', 'role': 'assistant', 'model': model,
            'content': content, 'stop_reason': stop, 'stop_sequence': None,
            'usage': {'input_tokens': usage.get('prompt_tokens', 0), 'output_tokens': usage.get('completion_tokens', 0),
                      'cache_read_input_tokens': (usage.get('prompt_tokens_details') or {}).get('cached_tokens', 0) or 0}}


class StreamTranslator:
    """OpenAI stream chunks in, Anthropic server-sent events out."""

    def __init__(self, model):
        self.model = model
        self.index = -1
        self.open = None          # 'thinking', 'text' or ('tool', openai index)
        self.started = False
        self.stop = None
        self.tool = False
        self.usage = {'input_tokens': 0, 'output_tokens': 0}

    @staticmethod
    def event(kind, data):
        return f'event: {kind}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n'.encode()

    def start(self):
        self.started = True
        return self.event('message_start', {'type': 'message_start', 'message': {
            'id': 'msg_' + uuid.uuid4().hex[:24], 'type': 'message', 'role': 'assistant', 'model': self.model,
            'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': dict(self.usage)}})

    def _close(self):
        if self.open is None: return b''
        self.open = None
        return self.event('content_block_stop', {'type': 'content_block_stop', 'index': self.index})

    def _begin(self, key, block):
        out = self._close()
        self.index += 1
        self.open = key
        return out + self.event('content_block_start', {'type': 'content_block_start', 'index': self.index, 'content_block': block})

    def _delta(self, delta):
        return self.event('content_block_delta', {'type': 'content_block_delta', 'index': self.index, 'delta': delta})

    def chunk(self, payload):
        out = b'' if self.started else self.start()
        usage = payload.get('usage')
        if isinstance(usage, dict):
            self.usage = {'input_tokens': usage.get('prompt_tokens', 0), 'output_tokens': usage.get('completion_tokens', 0)}
        for choice in payload.get('choices') or []:
            delta = choice.get('delta') or {}
            reasoning = delta.get('reasoning') or delta.get('reasoning_content')
            if reasoning:
                if self.open != 'thinking': out += self._begin('thinking', {'type': 'thinking', 'thinking': '', 'signature': ''})
                out += self._delta({'type': 'thinking_delta', 'thinking': reasoning})
            if delta.get('content'):
                if self.open != 'text': out += self._begin('text', {'type': 'text', 'text': ''})
                out += self._delta({'type': 'text_delta', 'text': delta['content']})
            for i, call in enumerate(delta.get('tool_calls') or []):
                fn = call.get('function') or {}
                key = ('tool', call.get('index', i))
                if self.open != key:
                    self.tool = True
                    out += self._begin(key, {'type': 'tool_use', 'id': _tool_id(call.get('id')), 'name': fn.get('name', ''), 'input': {}})
                arguments = fn.get('arguments')
                if isinstance(arguments, dict): arguments = json.dumps(arguments, ensure_ascii=False)
                if arguments: out += self._delta({'type': 'input_json_delta', 'partial_json': arguments})
            if choice.get('finish_reason'): self.stop = STOP.get(choice['finish_reason'], 'end_turn')
        return out

    def finish(self):
        out = (b'' if self.started else self.start()) + self._close()
        stop = 'tool_use' if self.tool else (self.stop or 'end_turn')
        return out + self.event('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None},
                                                  'usage': self.usage}) + \
            self.event('message_stop', {'type': 'message_stop'})


def count_tokens(body):
    """An estimate (about four characters a token): Claude Code uses it to decide when to compact."""
    request = to_openai(dict(body, stream=False))
    size = len(json.dumps(request.get('messages'), ensure_ascii=False)) + len(json.dumps(request.get('tools') or [], ensure_ascii=False))
    return {'input_tokens': max(1, size // 4)}


def error(kind, message):
    return {'type': 'error', 'error': {'type': kind, 'message': message}}


class AnthropicMessagesMixin:
    """POST /v1/messages and /v1/messages/count_tokens. Use before the handler that serves /v1/chat/completions."""

    def _anthropic_reply(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _anthropic_local(self):
        address = ipaddress.ip_address(self.client_address[0])
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped: address = address.ipv4_mapped
        return address.is_loopback and not self.headers.get('Origin')

    def _anthropic_upstream(self):
        host, port = self.server.server_address[:2]
        if host in ('', '0.0.0.0', '::') or not ipaddress.ip_address(host).is_loopback: host = '127.0.0.1'
        return f"http://{'[%s]' % host if ':' in host else host}:{port}"

    def _anthropic_model(self, requested):
        """The served model when the client names one this server doesn't list (Claude Code asks for claude-*)."""
        try:
            with urllib.request.urlopen(self._anthropic_upstream() + '/v1/models', timeout=10) as r:
                listed = {m.get('id') for m in json.loads(r.read()).get('data') or []}
        except (urllib.error.URLError, OSError, ValueError):
            listed = set()
        return requested if requested in listed else 'default_model'

    def do_POST(self):
        path = self.path.split('?', 1)[0].rstrip('/')
        if path not in PATHS: return super().do_POST()
        if not self._anthropic_local():
            return self._anthropic_reply(error('permission_error', 'The Anthropic API is available only to programs on this Mac'), 403)
        try:
            size = int(self.headers.get('Content-Length') or 0)
            if not 0 < size <= MAX_BODY: raise RequestError('The request body is empty or too large')
            body = json.loads(self.rfile.read(size))
            if path.endswith('/count_tokens'): return self._anthropic_reply(count_tokens(body))
            requested = str(body.get('model') or 'default_model')
            request = to_openai(body, self._anthropic_model(requested))
        except (RequestError, ValueError, UnicodeDecodeError) as e:
            return self._anthropic_reply(error('invalid_request_error', str(e)), 400)
        upstream = urllib.request.Request(self._anthropic_upstream() + '/v1/chat/completions', data=json.dumps(request).encode(),
                                          headers={'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(upstream, timeout=3600)
        except urllib.error.HTTPError as e:
            detail = e.read().decode('utf-8', 'replace')[:2000]
            return self._anthropic_reply(error('api_error', f'The model server answered {e.code}: {detail}'), 500 if e.code >= 500 else 400)
        except (urllib.error.URLError, OSError) as e:
            return self._anthropic_reply(error('api_error', f'The model server could not be reached: {e}'), 502)
        with response:
            if not request['stream']:
                return self._anthropic_reply(from_openai(json.loads(response.read()), requested))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'close')  # no length to frame it on a kept-alive HTTP/1.1 connection
            self.close_connection = True
            self.end_headers()
            stream = StreamTranslator(requested)
            for line in response:
                line = line.strip()
                if not line.startswith(b'data:'): continue
                value = line[5:].strip()
                if value == b'[DONE]': break
                try: payload = json.loads(value)
                except ValueError: continue
                if payload.get('error'):
                    self.wfile.write(stream.event('error', error('api_error', json.dumps(payload['error'])[:2000]))); self.wfile.flush()
                    return
                if (out := stream.chunk(payload)): self.wfile.write(out); self.wfile.flush()
            self.wfile.write(stream.finish()); self.wfile.flush()
