import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from dyno.apis import CodingAPIsMixin
from dyno.anthropic import StreamTranslator, count_tokens, from_openai, to_openai

TOOLS = [{'name': 'Read', 'description': 'Read a file', 'input_schema': {'type': 'object', 'properties': {'path': {'type': 'string'}}}},
         {'type': 'web_search_20250305', 'name': 'web_search'}]


def events(raw):
    out = []
    for frame in raw.decode().strip().split('\n\n'):
        kind, data = frame.split('\n', 1)
        out.append((kind[len('event: '):], json.loads(data[len('data: '):])))
    return out


class ToOpenAI(unittest.TestCase):
    def test_a_tool_round_trip_becomes_native_openai_messages(self):
        body = {'model': 'claude-sonnet', 'max_tokens': 512, 'system': [{'type': 'text', 'text': 'You are Claude Code.'}],
                'tools': TOOLS, 'tool_choice': {'type': 'any'}, 'temperature': 0.2, 'stop_sequences': ['END'],
                'thinking': {'type': 'enabled', 'budget_tokens': 1024},
                'messages': [
                    {'role': 'user', 'content': 'Read setup.py'},
                    {'role': 'assistant', 'content': [{'type': 'thinking', 'thinking': 'I should read it', 'signature': 'x'},
                                                      {'type': 'text', 'text': 'Reading.'},
                                                      {'type': 'tool_use', 'id': 'toolu_1', 'name': 'Read', 'input': {'path': 'setup.py'}}]},
                    {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': [{'type': 'text', 'text': 'print(1)'}]},
                                                 {'type': 'text', 'text': 'What does it do?'}]}]}
        r = to_openai(body)
        self.assertEqual(r['model'], 'default_model')
        self.assertEqual([m['role'] for m in r['messages']], ['system', 'user', 'assistant', 'tool', 'user'])
        self.assertEqual(r['messages'][2]['content'], 'Reading.')
        self.assertEqual(r['messages'][2]['tool_calls'][0]['function'], {'name': 'Read', 'arguments': '{"path": "setup.py"}'})
        self.assertEqual(r['messages'][3], {'role': 'tool', 'tool_call_id': 'toolu_1', 'content': 'print(1)'})
        self.assertEqual([t['function']['name'] for t in r['tools']], ['Read'])  # the server tool runs at Anthropic only
        self.assertEqual(r['tool_choice'], 'required')
        self.assertEqual((r['max_tokens'], r['temperature'], r['stop']), (512, 0.2, ['END']))
        self.assertEqual(r['chat_template_kwargs'], {'enable_thinking': True})
        self.assertFalse(r['stream'])

    def test_errors_images_and_streaming(self):
        r = to_openai({'stream': True, 'messages': [{'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 't', 'is_error': True, 'content': 'no such file'},
            {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'}},
            {'type': 'text', 'text': 'and this?'}]}]})
        self.assertEqual(r['messages'][0]['content'], 'Error: no such file')
        self.assertEqual(r['messages'][1]['content'][0]['image_url']['url'], 'data:image/png;base64,AAAA')
        self.assertEqual(r['stream_options'], {'include_usage': True})

    def test_a_system_message_in_the_conversation_is_user_text_where_it_stands(self):
        r = to_openai({'system': 'Top.', 'thinking': {'type': 'adaptive'}, 'messages': [
            {'role': 'user', 'content': [{'type': 'text', 'text': 'hi'}]},
            {'role': 'system', 'content': [{'type': 'text', 'text': '# Environment'}]}]})
        self.assertEqual(r['messages'], [{'role': 'system', 'content': 'Top.'}, {'role': 'user', 'content': 'hi\n\n# Environment'}])
        self.assertNotIn('chat_template_kwargs', r)

    def test_bad_requests_are_refused(self):
        for body in ([], {'messages': []}, {'messages': [{'role': 'tool', 'content': 'x'}]}):
            with self.assertRaises(ValueError): to_openai(body)


class FromOpenAI(unittest.TestCase):
    def test_a_completion_with_reasoning_and_a_tool_call(self):
        m = from_openai({'choices': [{'finish_reason': 'tool_calls', 'message': {
            'role': 'assistant', 'content': 'Let me look.', 'reasoning': 'hmm',
            'tool_calls': [{'id': 'call_9', 'type': 'function', 'function': {'name': 'Read', 'arguments': '{"path": "a"}'}}]}}],
            'usage': {'prompt_tokens': 40, 'completion_tokens': 7}}, 'claude-sonnet')
        self.assertEqual([b['type'] for b in m['content']], ['thinking', 'text', 'tool_use'])
        self.assertEqual(m['content'][2], {'type': 'tool_use', 'id': 'call_9', 'name': 'Read', 'input': {'path': 'a'}})
        self.assertEqual((m['stop_reason'], m['model'], m['usage']['input_tokens'], m['usage']['output_tokens']), ('tool_use', 'claude-sonnet', 40, 7))

    def test_length_is_max_tokens(self):
        m = from_openai({'choices': [{'finish_reason': 'length', 'message': {'content': 'abc'}}]}, 'm')
        self.assertEqual(m['stop_reason'], 'max_tokens')

    def test_a_stream_becomes_anthropic_events(self):
        s = StreamTranslator('claude-sonnet')
        raw = b''.join([
            s.chunk({'choices': [{'delta': {'reasoning': 'think'}}]}),
            s.chunk({'choices': [{'delta': {'content': 'Hi'}}]}),
            s.chunk({'choices': [{'delta': {'content': '!'}}]}),
            s.chunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'Read', 'arguments': '{"pa'}}]}}]}),
            s.chunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': 'th": 1}'}}]}}]}),
            s.chunk({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}], 'usage': {'prompt_tokens': 9, 'completion_tokens': 4}}),
            s.finish()])
        ev = events(raw)
        self.assertEqual([k for k, _ in ev], ['message_start', 'content_block_start', 'content_block_delta', 'content_block_stop',
                                              'content_block_start', 'content_block_delta', 'content_block_delta', 'content_block_stop',
                                              'content_block_start', 'content_block_delta', 'content_block_delta', 'content_block_stop',
                                              'message_delta', 'message_stop'])
        starts = [d['content_block'] for k, d in ev if k == 'content_block_start']
        self.assertEqual([b['type'] for b in starts], ['thinking', 'text', 'tool_use'])
        self.assertEqual((starts[2]['id'], starts[2]['name']), ('c1', 'Read'))
        json_parts = ''.join(d['delta']['partial_json'] for k, d in ev if k == 'content_block_delta' and d['delta']['type'] == 'input_json_delta')
        self.assertEqual(json.loads(json_parts), {'path': 1})
        self.assertEqual(ev[-2][1]['delta']['stop_reason'], 'tool_use')
        self.assertEqual(ev[-2][1]['usage'], {'input_tokens': 9, 'output_tokens': 4})

    def test_blank_lines_before_a_tool_call_are_not_a_text_block(self):
        s = StreamTranslator('m')
        ev = events(s.chunk({'choices': [{'delta': {'content': '\n\n', 'tool_calls': [{'index': 0, 'id': 'c', 'function': {'name': 'Read', 'arguments': '{}'}}]}}]}) + s.finish())
        self.assertEqual([d['content_block']['type'] for k, d in ev if k == 'content_block_start'], ['tool_use'])

    def test_count_tokens_is_an_estimate(self):
        self.assertGreater(count_tokens({'messages': [{'role': 'user', 'content': 'x' * 400}]})['input_tokens'], 90)


class FakeChat(BaseHTTPRequestHandler):
    """Stands in for mlx_lm: answers /v1/models and /v1/chat/completions, and remembers what it was sent."""
    seen = []

    def log_message(self, *a): pass

    def do_GET(self):
        body = json.dumps({'data': [{'id': 'mlx-community/Qwen3-8B-4bit'}]}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        FakeChat.seen.append(request)
        if request['stream']:
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            for chunk in ({'choices': [{'delta': {'content': 'Hel'}}]}, {'choices': [{'delta': {'content': 'lo'}, 'finish_reason': 'stop'}]},
                          {'choices': [], 'usage': {'prompt_tokens': 5, 'completion_tokens': 2}}):
                self.wfile.write(b'data: ' + json.dumps(chunk).encode() + b'\n\n')
            self.wfile.write(b'data: [DONE]\n\n')
        else:
            body = json.dumps({'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': 'Hello'}}],
                               'usage': {'prompt_tokens': 5, 'completion_tokens': 2}}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


class Handler(CodingAPIsMixin, FakeChat):
    pass


class OverHTTP(unittest.TestCase):
    def setUp(self):
        FakeChat.seen = []
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}'

    def tearDown(self):
        self.server.shutdown(); self.server.server_close()

    def post(self, path, body, headers=None):
        request = urllib.request.Request(self.url + path, data=json.dumps(body).encode(),
                                         headers={'Content-Type': 'application/json', 'x-api-key': 'local', **(headers or {})})
        return urllib.request.urlopen(request, timeout=10)

    def test_claude_code_gets_a_message_from_the_served_model(self):
        with self.post('/v1/messages', {'model': 'claude-opus-5-5', 'max_tokens': 20, 'messages': [{'role': 'user', 'content': 'hi'}]}) as r:
            m = json.loads(r.read())
        self.assertEqual((m['content'], m['model'], m['stop_reason']), ([{'type': 'text', 'text': 'Hello'}], 'claude-opus-5-5', 'end_turn'))
        # A model this server doesn't list is the served model, never a download.
        self.assertEqual(FakeChat.seen[0]['model'], 'default_model')

    def test_a_listed_model_is_passed_through_and_streams(self):
        with self.post('/v1/messages', {'model': 'mlx-community/Qwen3-8B-4bit', 'max_tokens': 20, 'stream': True,
                                        'messages': [{'role': 'user', 'content': 'hi'}]}) as r:
            self.assertEqual(r.headers['Content-Type'], 'text/event-stream')
            ev = events(r.read())
        self.assertEqual(FakeChat.seen[0]['model'], 'mlx-community/Qwen3-8B-4bit')
        self.assertEqual(''.join(d['delta']['text'] for k, d in ev if k == 'content_block_delta'), 'Hello')
        self.assertEqual(ev[-2][1]['usage'], {'input_tokens': 5, 'output_tokens': 2})

    def test_count_tokens_and_errors(self):
        with self.post('/v1/messages/count_tokens', {'model': 'x', 'messages': [{'role': 'user', 'content': 'hello there'}]}) as r:
            self.assertIn('input_tokens', json.loads(r.read()))
        with self.assertRaises(urllib.error.HTTPError) as bad:
            self.post('/v1/messages', {'model': 'x', 'messages': []})
        self.assertEqual(json.loads(bad.exception.read())['error']['type'], 'invalid_request_error')

    def test_a_web_page_cannot_use_it(self):
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.post('/v1/messages', {'messages': [{'role': 'user', 'content': 'hi'}]}, {'Origin': 'https://evil.example'})
        self.assertEqual(refused.exception.code, 403)
        self.assertEqual(FakeChat.seen, [])


if __name__ == '__main__':
    unittest.main()
