import json
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from dyno import apis
from dyno.apis import CodingAPIsMixin
from dyno.lab import websearch
from dyno.lab.websearch import WebSearch, paid_search

RESULTS = [{'title': 'Dyno Lab', 'url': 'https://dynolab.dev/', 'excerpt': 'Local AI research'}]


class SearchingChat(BaseHTTPRequestHandler):
    """A model that searches once, then answers."""
    seen = []

    def log_message(self, *a): pass

    def do_GET(self):
        body = b'{"data": []}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        SearchingChat.seen.append(request)
        searched = any(m['role'] == 'tool' for m in request['messages'])
        chunks = ([{'choices': [{'delta': {'content': 'Dyno Lab is at dynolab.dev.'}, 'finish_reason': 'stop'}]}] if searched else
                  [{'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'web_search', 'arguments': '{"query": "dyno lab"}'}}]}}]},
                   {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]}])
        chunks.append({'choices': [], 'usage': {'prompt_tokens': 50, 'completion_tokens': 5}})
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for c in chunks: self.wfile.write(b'data: ' + json.dumps(c).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')


class Handler(CodingAPIsMixin, SearchingChat):
    pass


def events(raw):
    return [json.loads(f.split('data: ', 1)[1]) for f in raw.decode().strip().split('\n\n')]


class HostedSearchRunsHere(unittest.TestCase):
    def setUp(self):
        SearchingChat.seen = []
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        self.search = mock.patch.object(apis, 'run_search', return_value=(RESULTS, None, json.dumps({'results': RESULTS})))
        self.ran = self.search.start()

    def tearDown(self):
        self.search.stop(); self.server.shutdown(); self.server.server_close()

    def post(self, path, body):
        return urllib.request.urlopen(urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                                             headers={'Content-Type': 'application/json'}), timeout=10)

    def test_claude_codes_web_search_tool(self):
        with self.post('/v1/messages', {'model': 'claude-haiku', 'max_tokens': 100, 'messages': [{'role': 'user', 'content': 'Find Dyno Lab'}],
                                        'tools': [{'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': 3}]}) as r:
            message = json.loads(r.read())
        self.ran.assert_called_once()
        self.assertEqual(self.ran.call_args[0][0], 'dyno lab')
        self.assertEqual([b['type'] for b in message['content']], ['server_tool_use', 'web_search_tool_result', 'text'])
        self.assertEqual(message['content'][0]['input'], {'query': 'dyno lab'})
        self.assertEqual(message['content'][1]['content'][0]['url'], 'https://dynolab.dev/')
        self.assertEqual((message['stop_reason'], message['usage']['server_tool_use']), ('end_turn', {'web_search_requests': 1}))
        self.assertEqual(message['usage']['output_tokens'], 10)
        # The model got the results as a tool message, after its own call.
        second = SearchingChat.seen[1]['messages']
        self.assertEqual([m['role'] for m in second[-2:]], ['assistant', 'tool'])
        self.assertEqual(second[-2]['tool_calls'][0]['function']['name'], 'web_search')

    def test_codexs_web_search_tool_streamed(self):
        with self.post('/v1/responses', {'model': 'm', 'stream': True, 'input': 'Find Dyno Lab',
                                         'tools': [{'type': 'function', 'name': 'exec_command', 'parameters': {}}, {'type': 'web_search'}]}) as r:
            ev = events(r.read())
        done = [e['item'] for e in ev if e['type'] == 'response.output_item.done']
        self.assertEqual([i['type'] for i in done], ['web_search_call', 'message'])
        self.assertEqual(done[0]['action']['query'], 'dyno lab')
        self.assertEqual(ev[-1]['type'], 'response.completed')
        self.assertEqual([o['type'] for o in ev[-1]['response']['output']], ['web_search_call', 'message'])
        self.assertEqual([t['function']['name'] for t in SearchingChat.seen[0]['tools']], ['exec_command', 'web_search'])

    def test_no_hosted_search_no_search_tool(self):
        with self.post('/v1/messages', {'model': 'x', 'max_tokens': 10, 'stream': True, 'messages': [{'role': 'user', 'content': 'hi'}]}) as r:
            r.read()
        self.assertNotIn('tools', SearchingChat.seen[0])
        self.ran.assert_not_called()


class Domains(unittest.TestCase):
    def test_allowed_and_blocked_domains(self):
        results = [{'url': 'https://arxiv.org/abs/1'}, {'url': 'https://export.arxiv.org/x'}, {'url': 'https://notarxiv.org/'}, {'url': 'https://x.com/a'}]
        self.assertEqual(len(apis.filter_domains(results, {'allowed_domains': ['arxiv.org']})), 2)
        self.assertEqual(len(apis.filter_domains(results, {'blocked_domains': ['x.com']})), 3)
        self.assertEqual(len(apis.filter_domains(results, {'filters': {'allowed_domains': ['x.com']}})), 1)
        self.assertEqual(len(apis.filter_domains(results, None)), 4)


class Providers(unittest.TestCase):
    def answer(self, payload):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(payload).encode()
        return response

    def test_each_paid_api_becomes_title_link_excerpt(self):
        cases = {'brave': {'web': {'results': [{'title': 'A', 'url': 'https://a', 'description': 'x'}]}},
                 'tavily': {'results': [{'title': 'A', 'url': 'https://a', 'content': 'x'}]},
                 'exa': {'results': [{'title': 'A', 'url': 'https://a', 'text': 'x'}]},
                 'serper': {'organic': [{'title': 'A', 'link': 'https://a', 'snippet': 'x'}]}}
        for provider, payload in cases.items():
            with mock.patch('urllib.request.urlopen', return_value=self.answer(payload)) as opened:
                self.assertEqual(paid_search(provider, 'k' * 20, 'q', 3), [('A', 'https://a', 'x')], provider)
            request = opened.call_args[0][0]
            self.assertTrue(request.full_url.startswith('https://'), provider)
            self.assertIn('k' * 20, json.dumps(dict(request.header_items())), provider)

    def test_settings_choose_a_provider_with_its_key_in_the_keychain(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = WebSearch(Path(tmp))
            self.assertEqual(web.provider, 'searxng')
            with mock.patch.object(websearch, 'api_key', return_value=None):
                with self.assertRaises(ValueError): web.configure({'provider': 'brave'})
            with mock.patch.object(websearch, 'save_key') as saved, mock.patch.object(websearch, 'api_key', return_value='k' * 20):
                state = web.configure({'provider': 'brave', 'api_key': 'k' * 20})
                saved.assert_called_once_with('brave', 'k' * 20)
                self.assertEqual(state['provider'], 'brave')
                self.assertTrue(next(p for p in state['providers'] if p['id'] == 'brave')['has_key'])
                self.assertTrue(web.ready())
            self.assertNotIn('k' * 20, (Path(tmp) / 'websearch' / 'provider.json').read_text())
            with self.assertRaises(ValueError): web.configure({'provider': 'nope'})

    def test_a_key_is_never_on_a_command_line(self):
        with mock.patch.object(websearch, '_keychain') as keychain:
            keychain.return_value.returncode = 0
            websearch.save_key('tavily', 'tvly-' + 'a' * 20)
        args, kwargs = keychain.call_args
        self.assertEqual(args, ('-i',))
        self.assertIn('tvly-' + 'a' * 20, kwargs['stdin'])
        with self.assertRaises(ValueError): websearch.save_key('tavily', 'bad key; rm -rf /')


if __name__ == '__main__':
    unittest.main()
