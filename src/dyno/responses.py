"""OpenAI's Responses API on top of Dyno's chat completions, so Codex (which speaks only Responses) can use a local model.

The same shape as the Anthropic translator: a Responses request becomes a chat completions request to this same
server, and the answer, or its stream, becomes Responses output items. Standard library only.
"""
from __future__ import annotations

import json
import time
import uuid

from .anthropic import RequestError

STATUS = {'length': 'incomplete'}


def _id(prefix):
    return f'{prefix}_{uuid.uuid4().hex[:24]}'


def _parts(content):
    """Responses content parts as chat content: a string when it's all text."""
    if isinstance(content, str): return content
    parts = []
    for part in content or []:
        if not isinstance(part, dict): continue
        if part.get('type') in ('input_text', 'output_text', 'text', 'refusal'):
            parts.append({'type': 'text', 'text': part.get('text') or part.get('refusal') or ''})
        elif part.get('type') == 'input_image' and isinstance(part.get('image_url'), str):
            parts.append({'type': 'image_url', 'image_url': {'url': part['image_url']}})
    if all(p['type'] == 'text' for p in parts): return '\n'.join(p['text'] for p in parts)
    return parts


def _output(value):
    if isinstance(value, str): return value
    text = _parts(value)
    return text if isinstance(text, str) else json.dumps(value, ensure_ascii=False)


def to_chat(body, model='default_model'):
    """A Responses request as a chat completions request."""
    if not isinstance(body, dict): raise RequestError('The request body must be a JSON object')
    items = body.get('input')
    if isinstance(items, str): items = [{'type': 'message', 'role': 'user', 'content': items}]
    if not isinstance(items, list) or not items: raise RequestError('input: give at least one item')
    messages = []
    if body.get('instructions'): messages.append({'role': 'system', 'content': str(body['instructions'])})

    def add_user(text):
        if messages and messages[-1]['role'] == 'user' and isinstance(messages[-1]['content'], str) and isinstance(text, str):
            messages[-1]['content'] += '\n\n' + text
        else:
            messages.append({'role': 'user', 'content': text})

    for item in items:
        if not isinstance(item, dict): raise RequestError('Each input item is an object')
        kind = item.get('type') or ('message' if 'role' in item else None)
        if kind == 'message':
            role, content = item.get('role'), _parts(item.get('content'))
            if role in ('system', 'developer'):
                # Only the first system message can stand as one: chat templates (Qwen's among them) refuse a later
                # one, so later instructions go in as user text where they stand.
                if all(m['role'] == 'system' for m in messages):
                    if messages: messages[0]['content'] += '\n\n' + _output(content)
                    else: messages.append({'role': 'system', 'content': _output(content)})
                else:
                    add_user(_output(content))
            elif role == 'assistant':
                messages.append({'role': 'assistant', 'content': _output(content)})
            elif role == 'user':
                add_user(content)
            else:
                raise RequestError(f'A message role is user, assistant, system or developer, not {role!r}')
        elif kind in ('function_call', 'custom_tool_call'):
            call = {'id': str(item.get('call_id') or item.get('id') or _id('call')), 'type': 'function',
                    'function': {'name': str(item.get('name', '')),
                                 'arguments': item.get('arguments') if kind == 'function_call' else json.dumps({'input': item.get('input', '')})}}
            last = messages[-1] if messages else None
            if last and last['role'] == 'assistant' and not any(m['role'] == 'tool' for m in messages[messages.index(last):]):
                last.setdefault('tool_calls', []).append(call)
            else:
                messages.append({'role': 'assistant', 'content': '', 'tool_calls': [call]})
        elif kind in ('function_call_output', 'custom_tool_call_output'):
            messages.append({'role': 'tool', 'tool_call_id': str(item.get('call_id', '')), 'content': _output(item.get('output'))})
        # reasoning items carry the model's earlier thinking (often encrypted); chat templates drop it anyway.
    request = {'model': model, 'messages': messages, 'stream': bool(body.get('stream'))}
    if isinstance(body.get('max_output_tokens'), int): request['max_tokens'] = body['max_output_tokens']
    for key in ('temperature', 'top_p'):
        if isinstance(body.get(key), (int, float)) and not isinstance(body.get(key), bool): request[key] = body[key]
    # Hosted tools (web search, file search) and MCP namespaces run at OpenAI; only plain functions can run here.
    tools = [t for t in body.get('tools') or [] if isinstance(t, dict) and t.get('type') == 'function' and t.get('name')]
    if tools:
        request['tools'] = [{'type': 'function', 'function': {'name': t['name'], 'description': t.get('description', ''),
                                                              'parameters': t.get('parameters') or {'type': 'object'}}} for t in tools]
        choice = body.get('tool_choice')
        if choice in ('none', 'required'): request['tool_choice'] = choice
        elif isinstance(choice, dict) and choice.get('type') == 'function':
            request['tool_choice'] = {'type': 'function', 'function': {'name': choice.get('name', '')}}
    effort = (body.get('reasoning') or {}).get('effort') if isinstance(body.get('reasoning'), dict) else None
    if effort in ('none', 'minimal'): request['chat_template_kwargs'] = {'enable_thinking': False}
    if request['stream']: request['stream_options'] = {'include_usage': True}
    return request


def _usage(usage):
    usage = usage or {}
    cached = (usage.get('prompt_tokens_details') or {}).get('cached_tokens', 0) or 0
    return {'input_tokens': usage.get('prompt_tokens', 0), 'input_tokens_details': {'cached_tokens': cached},
            'output_tokens': usage.get('completion_tokens', 0), 'output_tokens_details': {'reasoning_tokens': 0},
            'total_tokens': usage.get('prompt_tokens', 0) + usage.get('completion_tokens', 0)}


def _reasoning(text):
    return {'type': 'reasoning', 'id': _id('rs'), 'summary': [], 'content': [{'type': 'reasoning_text', 'text': text}]}


def _message(text):
    return {'type': 'message', 'id': _id('msg'), 'role': 'assistant', 'status': 'completed',
            'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}


def _call(call_id, name, arguments):
    return {'type': 'function_call', 'id': _id('fc'), 'call_id': call_id or _id('call'), 'name': name,
            'arguments': arguments if isinstance(arguments, str) else json.dumps(arguments or {}, ensure_ascii=False), 'status': 'completed'}


def _response(model, output, status, usage, response_id=None):
    return {'id': response_id or _id('resp'), 'object': 'response', 'created_at': int(time.time()), 'status': status,
            'model': model, 'output': output, 'usage': usage, 'error': None,
            'incomplete_details': {'reason': 'max_output_tokens'} if status == 'incomplete' else None}


def from_chat(response, model):
    choice = (response.get('choices') or [{}])[0]
    message = choice.get('message') or {}
    output = []
    reasoning = message.get('reasoning') or message.get('reasoning_content')
    if reasoning: output.append(_reasoning(reasoning))
    if message.get('content'): output.append(_message(message['content']))
    for call in message.get('tool_calls') or []:
        fn = call.get('function') or {}
        output.append(_call(call.get('id'), fn.get('name', ''), fn.get('arguments')))
    return _response(model, output, STATUS.get(choice.get('finish_reason'), 'completed'), _usage(response.get('usage')))


class StreamTranslator:
    """Chat completion chunks in, Responses server-sent events out."""

    def __init__(self, model, hidden=()):
        self.model, self.id = model, _id('resp')
        self.sequence = 0
        self.output = []          # finished items
        self.open = None          # the item being streamed: dict with 'kind' and its data
        self.finish = None
        self.usage = None
        self.spent = 0            # output tokens of earlier rounds
        self.started = False
        # Calls to tools Dyno runs itself (web search) are collected, not shown as the client's function calls.
        self.hidden = set(hidden)
        self.shown = False
        self.new_round()

    def new_round(self):
        """Before the model continues after Dyno ran its hidden calls: collect afresh."""
        if self.usage: self.spent += self.usage.get('completion_tokens', 0)
        self.usage = None if not self.usage else dict(self.usage, completion_tokens=0)
        self.text, self.calls, self.kinds, self.found, self.blank = '', {}, {}, {}, ''

    def event(self, kind, data):
        data = dict(type=kind, sequence_number=self.sequence, **data)
        self.sequence += 1
        return f'event: {kind}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n'.encode()

    def _start(self):
        self.started = True
        shell = _response(self.model, [], 'in_progress', None, self.id)
        return self.event('response.created', {'response': shell}) + self.event('response.in_progress', {'response': shell})

    def keepalive(self):
        """While the model reads a long prompt: another response.in_progress, so the client doesn't give up on a silent stream."""
        if not self.started: return self._start()
        return self.event('response.in_progress', {'response': _response(self.model, [], 'in_progress', None, self.id)})

    def _close(self):
        if not self.open: return b''
        item, kind, index = self.open['item'], self.open['kind'], self.open['index']
        self.open = None
        out = b''
        if kind == 'text':
            text = item['content'][0]['text']
            out += self.event('response.output_text.done', {'item_id': item['id'], 'output_index': index, 'content_index': 0, 'text': text})
            out += self.event('response.content_part.done', {'item_id': item['id'], 'output_index': index, 'content_index': 0, 'part': item['content'][0]})
        elif kind == 'reasoning':
            out += self.event('response.reasoning_text.done', {'item_id': item['id'], 'output_index': index, 'content_index': 0,
                                                               'text': item['content'][0]['text']})
        elif kind == 'call':
            out += self.event('response.function_call_arguments.done', {'item_id': item['id'], 'output_index': index, 'arguments': item['arguments']})
        item['status'] = 'completed'
        self.output.append(item)
        return out + self.event('response.output_item.done', {'output_index': index, 'item': item})

    def _begin(self, kind, item):
        out = self._close()
        index = len(self.output)
        self.open = dict(kind=kind, item=item, index=index)
        shown = dict(item, status='in_progress')
        out += self.event('response.output_item.added', {'output_index': index, 'item': shown})
        if kind == 'text':
            out += self.event('response.content_part.added', {'item_id': item['id'], 'output_index': index, 'content_index': 0,
                                                              'part': {'type': 'output_text', 'text': '', 'annotations': []}})
        return out

    def chunk(self, payload):
        out = b'' if self.started else self._start()
        if isinstance(payload.get('usage'), dict): self.usage = payload['usage']
        for choice in payload.get('choices') or []:
            delta = choice.get('delta') or {}
            reasoning = delta.get('reasoning') or delta.get('reasoning_content')
            if reasoning:
                if not self.open or self.open['kind'] != 'reasoning': out += self._begin('reasoning', _reasoning(''))
                item = self.open['item']; item['content'][0]['text'] += reasoning
                out += self.event('response.reasoning_text.delta', {'item_id': item['id'], 'output_index': self.open['index'],
                                                                    'content_index': 0, 'delta': reasoning})
            if delta.get('content'):
                self.text += delta['content']
                text = delta['content']
                if not self.open or self.open['kind'] != 'text':
                    # Blank lines before a tool call would show as an empty message: hold them until text comes.
                    self.blank += text
                    text = ''
                    if self.blank.strip():
                        text, self.blank = self.blank.lstrip(), ''
                        out += self._begin('text', _message(''))
                if text:
                    item = self.open['item']; item['content'][0]['text'] += text
                    out += self.event('response.output_text.delta', {'item_id': item['id'], 'output_index': self.open['index'],
                                                                     'content_index': 0, 'delta': text})
            for i, call in enumerate(delta.get('tool_calls') or []):
                fn = call.get('function') or {}
                key = call.get('index', i)
                if key not in self.kinds: self.kinds[key] = 'hidden' if fn.get('name') in self.hidden else 'shown'
                if self.kinds[key] == 'hidden':
                    found = self.found.setdefault(key, {'id': call.get('id') or _id('call'), 'name': fn.get('name', ''), 'arguments': ''})
                    arguments = fn.get('arguments')
                    found['arguments'] += json.dumps(arguments) if isinstance(arguments, dict) else (arguments or '')
                    continue
                self.shown = True
                if key not in self.calls:
                    self.calls[key] = _call(call.get('id'), fn.get('name', ''), '')
                    out += self._begin('call', self.calls[key])
                item = self.calls[key]
                arguments = fn.get('arguments')
                if isinstance(arguments, dict): arguments = json.dumps(arguments, ensure_ascii=False)
                if arguments:
                    item['arguments'] += arguments
                    out += self.event('response.function_call_arguments.delta', {'item_id': item['id'], 'output_index': self.open['index'],
                                                                                 'delta': arguments})
            if choice.get('finish_reason'): self.finish = choice['finish_reason']
        return out

    def hidden_calls(self):
        """Dyno's own calls this round, unless the model also called a client tool (then the client goes first)."""
        return [] if self.shown else list(self.found.values())

    def _total(self):
        usage = dict(self.usage or {})
        usage['completion_tokens'] = self.spent + usage.get('completion_tokens', 0)
        return _usage(usage)

    def searched(self, call, query, results, error=None):
        """A search Dyno ran, shown as the Responses API's web_search_call item."""
        out = (b'' if self.started else self._start()) + self._close()
        item = {'type': 'web_search_call', 'id': _id('ws'), 'status': 'in_progress', 'action': {'type': 'search', 'query': query}}
        index = len(self.output)
        out += self.event('response.output_item.added', {'output_index': index, 'item': dict(item)})
        out += self.event('response.web_search_call.in_progress', {'output_index': index, 'item_id': item['id']})
        out += self.event('response.web_search_call.searching', {'output_index': index, 'item_id': item['id']})
        item['status'] = 'failed' if error else 'completed'
        if not error: item['action']['sources'] = [{'type': 'url', 'url': r['url']} for r in results]
        out += self.event('response.web_search_call.completed', {'output_index': index, 'item_id': item['id']})
        self.output.append(item)
        return out + self.event('response.output_item.done', {'output_index': index, 'item': item})

    def done(self):
        out = (b'' if self.started else self._start()) + self._close()
        finish = self.finish if not (self.finish == 'tool_calls' and not self.shown) else 'stop'
        status = STATUS.get(finish, 'completed')
        final = _response(self.model, self.output, status, self._total(), self.id)
        return out + self.event('response.completed' if status == 'completed' else 'response.incomplete', {'response': final})

    def failed(self, message):
        final = _response(self.model, self.output, 'failed', self._total(), self.id)
        final['error'] = {'code': 'server_error', 'message': message}
        return (b'' if self.started else self._start()) + self.event('response.failed', {'response': final})


def collect(raw):
    """The final response a stream of these events describes, for a client that didn't ask to stream."""
    final = None
    for frame in raw.decode().split('\n\n'):
        if 'data: ' in frame:
            data = json.loads(frame.split('data: ', 1)[1])
            if data['type'] in ('response.completed', 'response.incomplete', 'response.failed'): final = data['response']
    return final
