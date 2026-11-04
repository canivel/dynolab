import json
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from dyno import apis, webaccess
from dyno.apis import CodingAPIsMixin

RESULTS = [{'title': 'Dyno Lab', 'url': 'https://dynolab.dev/', 'excerpt': 'Local AI research'}]
PAGE = {'url': 'https://dynolab.dev/', 'title': 'Dyno Lab', 'text': 'Dyno Lab 0.6.17 is out.', 'untrusted': 'x'}


def call(name, arguments):
    return [{'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c-' + name, 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}}]},
            {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]}]


class BrowsingChat(BaseHTTPRequestHandler):
    """A model that searches, reads the first result, then answers. Requests with their own tools get a plain answer."""
    seen = []

    def log_message(self, *a): pass

    def do_GET(self):
        body = b'{"data": []}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        BrowsingChat.seen.append((dict(self.headers), request))
        done = [m.get('tool_call_id') for m in request['messages'] if m['role'] == 'tool']
        offered = [t['function']['name'] for t in request.get('tools') or []]
        if 'web_search' not in offered or 'c-read_page' in done:
            chunks = [{'choices': [{'delta': {'content': 'It is out.'}, 'finish_reason': 'stop'}]}]
        elif 'c-web_search' in done:
            chunks = call('read_page', {'url': 'https://dynolab.dev/'})
        else:
            chunks = [{'choices': [{'delta': {'role': 'assistant', 'content': 'Looking. '}}]}, *call('web_search', {'query': 'dyno lab release'})]
        chunks.append({'choices': [], 'usage': {'prompt_tokens': 40, 'completion_tokens': 3}})
        if not request.get('stream'):
            body = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'plain'}, 'finish_reason': 'stop'}]}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for c in chunks: self.wfile.write(b'data: ' + json.dumps(c).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')


class Handler(CodingAPIsMixin, BrowsingChat):
    web_access = True


def data(raw):
    return [f.split('data: ', 1)[1] for f in raw.decode().strip().split('\n\n') if f.startswith('data: ')]


class WebAccess(unittest.TestCase):
    def setUp(self):
        BrowsingChat.seen = []
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        self.patches = [mock.patch.object(apis, 'run_search', return_value=(RESULTS, None, json.dumps({'results': RESULTS}))),
                        mock.patch.object(apis, 'run_read', return_value=(PAGE, None, json.dumps(PAGE)))]
        self.searched, self.read = [p.start() for p in self.patches]

    def tearDown(self):
        for p in self.patches: p.stop()
        self.server.shutdown(); self.server.server_close()

    def post(self, body, path='/v1/chat/completions', headers=None):
        return urllib.request.urlopen(urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                                             headers={'Content-Type': 'application/json', **(headers or {})}), timeout=10)

    def test_a_chat_app_gets_an_answer_from_the_web_streamed(self):
        with self.post({'model': 'm', 'stream': True, 'messages': [{'role': 'system', 'content': 'Be brief.'}, {'role': 'user', 'content': 'Is 0.6.17 out?'}]}) as r:
            frames = data(r.read())
        self.assertEqual(frames[-1], '[DONE]')
        chunks = [json.loads(f) for f in frames[:-1]]
        text = ''.join(c['choices'][0]['delta'].get('content') or '' for c in chunks if c['choices'])
        self.assertEqual(text, 'Looking. It is out.')
        # The client sees no tool calls, one finish reason and the usage of all three rounds, under one id.
        self.assertFalse(any('tool_calls' in c['choices'][0]['delta'] for c in chunks if c['choices']))
        self.assertEqual([c['choices'][0]['finish_reason'] for c in chunks if c['choices'] and c['choices'][0]['finish_reason']], ['stop'])
        self.assertEqual(chunks[-1]['usage']['completion_tokens'], 9)
        self.assertEqual(len({c['id'] for c in chunks}), 1)
        self.assertEqual(self.searched.call_args[0][0], 'dyno lab release')
        self.assertEqual(self.read.call_args[0][0], 'https://dynolab.dev/')
        # The model was told it has the tools, at the end of the client's own system prompt, on every round.
        headers, first = BrowsingChat.seen[0]
        self.assertEqual(headers.get('X-Dyno-Inner'), '1')
        self.assertTrue(first['messages'][0]['content'].startswith('Be brief.\n\n'))
        self.assertIn('read_page', first['messages'][0]['content'])
        self.assertEqual([t['function']['name'] for t in first['tools']], ['web_search', 'read_page'])
        last = BrowsingChat.seen[-1][1]['messages']
        self.assertEqual([m['role'] for m in last[-4:]], ['assistant', 'tool', 'assistant', 'tool'])

    def test_not_streamed_one_completion(self):
        with self.post({'model': 'm', 'messages': [{'role': 'user', 'content': 'Is 0.6.17 out?'}]}) as r:
            answer = json.loads(r.read())
        self.assertEqual(answer['object'], 'chat.completion')
        self.assertEqual(answer['choices'][0]['message'], {'role': 'assistant', 'content': 'Looking. It is out.'})
        self.assertEqual(answer['choices'][0]['finish_reason'], 'stop')
        self.assertEqual(BrowsingChat.seen[0][1]['messages'][0]['role'], 'system')  # added: the client had none

    def test_requests_with_their_own_tools_pass_through_unchanged(self):
        tools = [{'type': 'function', 'function': {'name': 'Read', 'parameters': {}}}]
        with self.post({'model': 'm', 'messages': [{'role': 'user', 'content': 'hi'}], 'tools': tools}) as r:
            self.assertEqual(json.loads(r.read())['choices'][0]['message']['content'], 'plain')
        self.assertEqual(BrowsingChat.seen[0][1]['tools'], tools)
        self.assertNotIn('X-Dyno-Inner', BrowsingChat.seen[0][0])
        self.searched.assert_not_called()

    def test_off_by_default_and_never_for_a_web_page(self):
        Handler.web_access = False
        try:
            with self.post({'model': 'm', 'messages': [{'role': 'user', 'content': 'hi'}]}) as r: r.read()
        finally:
            Handler.web_access = True
        with self.post({'model': 'm', 'messages': [{'role': 'user', 'content': 'hi'}]}, headers={'Origin': 'https://evil.example'}) as r: r.read()
        self.assertTrue(all('tools' not in request for _, request in BrowsingChat.seen))

    def test_claudes_web_fetch_tool_reads_the_page_here(self):
        with self.post({'model': 'claude-x', 'max_tokens': 50, 'messages': [{'role': 'user', 'content': 'Is 0.6.17 out?'}],
                        'tools': [{'type': 'web_search_20250305', 'name': 'web_search'}, {'type': 'web_fetch_20250910', 'name': 'web_fetch'}]},
                       path='/v1/messages') as r:
            message = json.loads(r.read())
        # The fake model calls read_page; on the Messages API the reader is named web_fetch, so it answers after the search.
        kinds = [b['type'] for b in message['content']]
        self.assertEqual(kinds[:3], ['text', 'server_tool_use', 'web_search_tool_result'])
        self.assertEqual(message['usage']['server_tool_use'], {'web_search_requests': 1})
        self.assertEqual([t['function']['name'] for t in BrowsingChat.seen[0][1]['tools']], ['web_search', 'web_fetch'])


class Fetched(unittest.TestCase):
    def test_a_page_read_is_anthropics_web_fetch_blocks(self):
        from dyno.anthropic import StreamTranslator, collect
        stream = StreamTranslator('claude-x', hidden={'web_fetch'})
        raw = stream.fetched({'id': 'srv1'}, 'https://dynolab.dev/', PAGE) + stream.fetched({'id': 'srv2'}, 'http://10.0.0.1/', None, 'private') + stream.finish()
        message = collect(raw)
        use, result, _, failed = message['content']
        self.assertEqual((use['name'], use['input']), ('web_fetch', {'url': 'https://dynolab.dev/'}))
        self.assertEqual(result['content']['content']['source']['data'], 'Dyno Lab 0.6.17 is out.')
        self.assertEqual(failed['content'], {'type': 'web_fetch_tool_error', 'error_code': 'url_not_accessible'})
        self.assertEqual(message['usage']['server_tool_use'], {'web_fetch_requests': 2})


class Requests(unittest.TestCase):
    def test_which_requests_get_web_access(self):
        self.assertTrue(webaccess.wants_web({'messages': []}))
        self.assertTrue(webaccess.wants_web({'messages': [], 'tools': []}))
        self.assertFalse(webaccess.wants_web({'messages': [], 'tools': [{'type': 'function'}]}))
        self.assertFalse(webaccess.wants_web({'prompt': 'hi'}))
        request = webaccess.with_web({'messages': [{'role': 'user', 'content': 'hi'}], 'tool_choice': 'none'})
        self.assertEqual((request['messages'][0]['role'], request['stream'], 'tool_choice' in request), ('system', True, False))

    def test_read_page_refuses_this_mac_and_the_local_network(self):
        for url in ('http://127.0.0.1:8971/v1/models', 'http://localhost:8970/', 'http://192.168.1.10/', 'file:///etc/passwd'):
            page, error, text = apis.run_read(url)
            self.assertIsNone(page, url)
            self.assertTrue(text.startswith('Reading the page failed'), url)


if __name__ == '__main__':
    unittest.main()
