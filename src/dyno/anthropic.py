"""Anthropic Messages API on top of Dyno's chat completions, so Claude Code and Anthropic SDKs can use a local model.

A Messages request becomes a chat completions request to this same server, and the answer (or its stream) is
translated back; `apis.py` serves it. Standard library only.
"""
from __future__ import annotations

import json
import uuid

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

    def __init__(self, model, hidden=()):
        self.model = model
        self.index = -1
        self.open = None          # 'thinking', 'text' or ('tool', openai index)
        self.started = False
        self.stop = None
        self.tool = False
        self.usage = {'input_tokens': 0, 'output_tokens': 0}
        self.spent = 0            # output tokens of earlier rounds
        self.searches = 0
        # Calls to tools Dyno runs itself (web search) are collected, not shown as the client's tool_use.
        self.hidden = set(hidden)
        self.new_round()

    def new_round(self):
        """Before the model continues after Dyno ran its hidden calls: collect afresh."""
        self.spent = self.usage['output_tokens']  # usage is cumulative across rounds
        self.text, self.calls, self.kinds, self.blank = '', {}, {}, ''

    @staticmethod
    def event(kind, data):
        return f'event: {kind}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n'.encode()

    def start(self):
        self.started = True
        return self.event('message_start', {'type': 'message_start', 'message': {
            'id': 'msg_' + uuid.uuid4().hex[:24], 'type': 'message', 'role': 'assistant', 'model': self.model,
            'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': dict(self.usage)}})

    def keepalive(self):
        """While the model reads a long prompt: Anthropic's ping event, so the client doesn't give up on a silent stream."""
        return (b'' if self.started else self.start()) + self.event('ping', {'type': 'ping'})

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
            self.usage = {'input_tokens': usage.get('prompt_tokens', 0), 'output_tokens': self.spent + usage.get('completion_tokens', 0)}
        for choice in payload.get('choices') or []:
            delta = choice.get('delta') or {}
            reasoning = delta.get('reasoning') or delta.get('reasoning_content')
            if reasoning:
                if self.open != 'thinking': out += self._begin('thinking', {'type': 'thinking', 'thinking': '', 'signature': ''})
                out += self._delta({'type': 'thinking_delta', 'thinking': reasoning})
            if delta.get('content'):
                self.text += delta['content']
                text = delta['content']
                if self.open != 'text':
                    # Blank lines before a tool call would show as an empty text block: hold them until text comes.
                    self.blank += text
                    text = ''
                    if self.blank.strip():
                        text, self.blank = self.blank.lstrip(), ''
                        out += self._begin('text', {'type': 'text', 'text': ''})
                if text: out += self._delta({'type': 'text_delta', 'text': text})
            for i, call in enumerate(delta.get('tool_calls') or []):
                fn = call.get('function') or {}
                key = ('tool', call.get('index', i))
                if key not in self.kinds: self.kinds[key] = 'hidden' if fn.get('name') in self.hidden else 'shown'
                if self.kinds[key] == 'hidden':
                    found = self.calls.setdefault(key, {'id': _tool_id(call.get('id')), 'name': fn.get('name', ''), 'arguments': ''})
                    arguments = fn.get('arguments')
                    found['arguments'] += json.dumps(arguments) if isinstance(arguments, dict) else (arguments or '')
                    continue
                if self.open != key:
                    self.tool = True
                    out += self._begin(key, {'type': 'tool_use', 'id': _tool_id(call.get('id')), 'name': fn.get('name', ''), 'input': {}})
                arguments = fn.get('arguments')
                if isinstance(arguments, dict): arguments = json.dumps(arguments, ensure_ascii=False)
                if arguments: out += self._delta({'type': 'input_json_delta', 'partial_json': arguments})
            if choice.get('finish_reason'): self.stop = STOP.get(choice['finish_reason'], 'end_turn')
        return out

    def hidden_calls(self):
        """Dyno's own calls this round, unless the model also called a client tool (then the client goes first)."""
        return [] if self.tool else list(self.calls.values())

    def searched(self, call, query, results, error=None):
        """A search Dyno ran, shown as Anthropic's server tool blocks."""
        self.searches += 1
        out = (b'' if self.started else self.start())
        out += self._begin(('server', self.index + 1), {'type': 'server_tool_use', 'id': call['id'], 'name': 'web_search', 'input': {}})
        out += self._delta({'type': 'input_json_delta', 'partial_json': json.dumps({'query': query}, ensure_ascii=False)})
        content = ({'type': 'web_search_tool_result_error', 'error_code': 'unavailable'} if error else
                   [{'type': 'web_search_result', 'title': r['title'], 'url': r['url'], 'encrypted_content': '', 'page_age': None} for r in results])
        out += self._begin(('result', self.index + 1), {'type': 'web_search_tool_result', 'tool_use_id': call['id'], 'content': content})
        return out + self._close()

    def finish(self):
        out = (b'' if self.started else self.start()) + self._close()
        stop = 'tool_use' if self.tool else (self.stop if self.stop not in (None, 'tool_use') else 'end_turn')
        usage = dict(self.usage, server_tool_use={'web_search_requests': self.searches}) if self.searches else self.usage
        return out + self.event('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None},
                                                  'usage': usage}) + \
            self.event('message_stop', {'type': 'message_stop'})


def collect(raw):
    """The message a stream of these events describes, for a client that didn't ask to stream."""
    message, blocks = None, []
    for frame in raw.decode().split('\n\n'):
        if not frame.strip(): continue
        data = json.loads(frame.split('data: ', 1)[1])
        kind = data['type']
        if kind == 'message_start': message = data['message']
        elif kind == 'content_block_start': blocks.append(dict(data['content_block'], _json=''))
        elif kind == 'content_block_delta':
            delta, block = data['delta'], blocks[-1]
            if delta['type'] == 'text_delta': block['text'] += delta['text']
            elif delta['type'] == 'thinking_delta': block['thinking'] += delta['thinking']
            elif delta['type'] == 'input_json_delta': block['_json'] += delta['partial_json']
        elif kind == 'message_delta':
            message.update(stop_reason=data['delta']['stop_reason'], usage=data['usage'])
    for block in blocks:
        raw_json = block.pop('_json')
        if block['type'] in ('tool_use', 'server_tool_use'): block['input'] = _input(raw_json)
    message['content'] = blocks
    return message


def count_tokens(body):
    """An estimate (about four characters a token): Claude Code uses it to decide when to compact."""
    request = to_openai(dict(body, stream=False))
    size = len(json.dumps(request.get('messages'), ensure_ascii=False)) + len(json.dumps(request.get('tools') or [], ensure_ascii=False))
    return {'input_tokens': max(1, size // 4)}


def error(kind, message):
    return {'type': 'error', 'error': {'type': kind, 'message': message}}
