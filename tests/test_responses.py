import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from dyno.responses import StreamTranslator, from_chat, to_chat

from test_anthropic import FakeChat, Handler


def events(raw):
    out = []
    for frame in raw.decode().strip().split('\n\n'):
        kind, data = frame.split('\n', 1)
        out.append((kind[len('event: '):], json.loads(data[len('data: '):])))
    return out


class ToChat(unittest.TestCase):
    def test_a_codex_turn_with_a_tool_round_trip(self):
        body = {'model': 'Qwen3-8B-4bit', 'instructions': 'You are Codex.', 'stream': True, 'max_output_tokens': 300,
                'reasoning': {'effort': 'medium'}, 'tool_choice': 'auto',
                'tools': [{'type': 'function', 'name': 'exec_command', 'description': 'Run', 'parameters': {'type': 'object'}, 'strict': False},
                          {'type': 'namespace', 'name': 'mcp__github', 'tools': []}, {'type': 'web_search'}],
                'input': [
                    {'type': 'message', 'role': 'developer', 'content': [{'type': 'input_text', 'text': 'Sandbox: read-only.'}]},
                    {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': '<environment_context/>'}]},
                    {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'List files'}]},
                    {'type': 'reasoning', 'id': 'rs_1', 'summary': [], 'encrypted_content': 'xx'},
                    {'type': 'function_call', 'call_id': 'call_1', 'name': 'exec_command', 'arguments': '{"cmd":"ls"}'},
                    {'type': 'function_call_output', 'call_id': 'call_1', 'output': 'a.py\nb.py'},
                    {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Two files.'}]},
                    {'type': 'message', 'role': 'developer', 'content': [{'type': 'input_text', 'text': 'Mode changed.'}]},
                    {'type': 'message', 'role': 'user', 'content': 'thanks'}]}
        r = to_chat(body)
        self.assertEqual([m['role'] for m in r['messages']], ['system', 'user', 'assistant', 'tool', 'assistant', 'user'])
        self.assertEqual(r['messages'][0]['content'], 'You are Codex.\n\nSandbox: read-only.')
        self.assertEqual(r['messages'][1]['content'], '<environment_context/>\n\nList files')
        self.assertEqual(r['messages'][2]['tool_calls'][0], {'id': 'call_1', 'type': 'function', 'function': {'name': 'exec_command', 'arguments': '{"cmd":"ls"}'}})
        self.assertEqual(r['messages'][3], {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'a.py\nb.py'})
        self.assertEqual(r['messages'][5]['content'], 'Mode changed.\n\nthanks')  # a later developer message is user text
        self.assertEqual([t['function']['name'] for t in r['tools']], ['exec_command'])
        self.assertNotIn('tool_choice', r)
        self.assertEqual((r['max_tokens'], r['stream_options']), (300, {'include_usage': True}))

    def test_a_plain_string_input_and_minimal_effort(self):
        r = to_chat({'input': 'hello', 'reasoning': {'effort': 'minimal'}})
        self.assertEqual(r['messages'], [{'role': 'user', 'content': 'hello'}])
        self.assertEqual(r['chat_template_kwargs'], {'enable_thinking': False})

    def test_bad_requests_are_refused(self):
        for body in ([], {'input': []}, {'input': [{'type': 'message', 'role': 'robot', 'content': 'x'}]}):
            with self.assertRaises(ValueError): to_chat(body)


class FromChat(unittest.TestCase):
    def test_a_completion_with_reasoning_and_a_call(self):
        r = from_chat({'choices': [{'finish_reason': 'tool_calls', 'message': {'content': 'Looking.', 'reasoning': 'hmm',
                       'tool_calls': [{'id': 'c9', 'function': {'name': 'exec_command', 'arguments': '{"cmd": "ls"}'}}]}}],
                       'usage': {'prompt_tokens': 10, 'completion_tokens': 3}}, 'm')
        self.assertEqual([o['type'] for o in r['output']], ['reasoning', 'message', 'function_call'])
        self.assertEqual((r['output'][2]['call_id'], r['output'][2]['arguments']), ('c9', '{"cmd": "ls"}'))
        self.assertEqual((r['status'], r['usage']['total_tokens']), ('completed', 13))
        self.assertEqual(from_chat({'choices': [{'finish_reason': 'length', 'message': {'content': 'x'}}]}, 'm')['status'], 'incomplete')

    def test_a_stream_becomes_responses_events(self):
        s = StreamTranslator('m')
        raw = b''.join([
            s.chunk({'choices': [{'delta': {'content': 'Hi'}}]}),
            s.chunk({'choices': [{'delta': {'content': ' there'}}]}),
            s.chunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'exec_command', 'arguments': '{"cmd"'}}]}}]}),
            s.chunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': ': "ls"}'}}]}}]}),
            s.chunk({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}], 'usage': {'prompt_tokens': 9, 'completion_tokens': 4}}),
            s.done()])
        ev = events(raw)
        kinds = [k for k, _ in ev]
        self.assertEqual(kinds[:2], ['response.created', 'response.in_progress'])
        self.assertEqual(kinds[-1], 'response.completed')
        self.assertEqual([d['sequence_number'] for _, d in ev], list(range(len(ev))))
        done = [d['item'] for k, d in ev if k == 'response.output_item.done']
        self.assertEqual(done[0]['content'][0]['text'], 'Hi there')
        self.assertEqual((done[1]['type'], done[1]['call_id'], json.loads(done[1]['arguments'])), ('function_call', 'c1', {'cmd': 'ls'}))
        final = ev[-1][1]['response']
        self.assertEqual([o['type'] for o in final['output']], ['message', 'function_call'])
        self.assertEqual(final['usage']['input_tokens'], 9)


class OverHTTP(unittest.TestCase):
    def setUp(self):
        FakeChat.seen = []
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}/v1/responses'

    def tearDown(self):
        self.server.shutdown(); self.server.server_close()

    def post(self, body, headers=None):
        return urllib.request.urlopen(urllib.request.Request(self.url, data=json.dumps(body).encode(),
                                                             headers={'Content-Type': 'application/json', **(headers or {})}), timeout=10)

    def test_codex_streams_from_the_served_model(self):
        with self.post({'model': 'Qwen3-8B-4bit', 'stream': True, 'input': 'hi'}) as r:
            ev = events(r.read())
        self.assertEqual(FakeChat.seen[0]['model'], 'default_model')
        self.assertEqual(''.join(d['delta'] for k, d in ev if k == 'response.output_text.delta'), 'Hello')
        self.assertEqual(ev[-1][0], 'response.completed')

    def test_not_streamed_and_refusals(self):
        with self.post({'model': 'x', 'input': 'hi'}) as r:
            self.assertEqual(json.loads(r.read())['output'][0]['content'][0]['text'], 'Hello')
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.post({'input': 'hi'}, {'Origin': 'https://evil.example'})
        self.assertEqual(refused.exception.code, 403)
        self.assertIn('error', json.loads(refused.exception.read()))


if __name__ == '__main__':
    unittest.main()
