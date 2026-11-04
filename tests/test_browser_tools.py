import json
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from dyno import apis, webaccess
from dyno.apis import CodingAPIsMixin


class FakeBrowser(BaseHTTPRequestHandler):
    """Stands in for the Dyno app's browser bridge."""
    token, seen, mode = 'secret', [], 'read'

    def log_message(self, *a): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
        if self.headers.get('Authorization') != f'Bearer {FakeBrowser.token}':
            answer, status = {'ok': False, 'error': 'Wrong or missing token'}, 401
        else:
            action = self.path.rsplit('/', 1)[1]
            FakeBrowser.seen.append((action, body))
            status = 200
            if action == 'status': answer = {'ok': True, 'mode': FakeBrowser.mode, 'paused': False, 'mode_line': 'Browser mode: read only.'}
            elif action == 'click': answer = {'ok': False, 'error': 'The browser is in read-only mode'}
            else: answer = {'ok': True, 'page': 'Page: Dyno Lab\nAddress: https://dynolab.dev/\n[1] link “Docs” → https://dynolab.dev/docs'}
        data = json.dumps(answer).encode()
        self.send_response(status); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)


class BrowsingModel(BaseHTTPRequestHandler):
    """A model that opens a page in the browser, then answers."""
    seen = []

    def log_message(self, *a): pass

    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}')

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        BrowsingModel.seen.append(request)
        opened = any(m['role'] == 'tool' for m in request['messages'])
        chunks = ([{'choices': [{'delta': {'content': 'Dyno Lab has docs.'}, 'finish_reason': 'stop'}]}] if opened else
                  [{'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'b1', 'function': {'name': 'browser_open', 'arguments': '{"url": "https://dynolab.dev"}'}}]}}]},
                   {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]}])
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for c in chunks: self.wfile.write(b'data: ' + json.dumps(c).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')


class Handler(CodingAPIsMixin, BrowsingModel):
    web_access = True


def serve(handler):
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class BrowserTools(unittest.TestCase):
    def setUp(self):
        FakeBrowser.seen, BrowsingModel.seen = [], []
        self.browser, self.model = serve(FakeBrowser), serve(Handler)
        self.folder = tempfile.TemporaryDirectory()
        self.file = Path(self.folder.name) / 'browser.json'
        self.file.write_text(json.dumps({'port': self.browser.server_address[1], 'token': FakeBrowser.token}))
        self.patches = [mock.patch.object(webaccess, 'BRIDGE', self.file), mock.patch.dict(webaccess._status, at=0.0, value=None)]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in self.patches: p.stop()
        for s in (self.browser, self.model): s.shutdown(); s.server_close()
        self.folder.cleanup()

    def test_the_model_uses_the_apps_browser(self):
        url = f'http://127.0.0.1:{self.model.server_address[1]}/v1/chat/completions'
        request = urllib.request.Request(url, data=json.dumps({'model': 'm', 'messages': [{'role': 'user', 'content': 'What is on dynolab.dev?'}]}).encode(),
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as r: answer = json.loads(r.read())
        self.assertEqual(answer['choices'][0]['message']['content'], 'Dyno Lab has docs.')
        first = BrowsingModel.seen[0]
        self.assertIn('browser_click', [t['function']['name'] for t in first['tools']])
        self.assertIn('Browser mode: read only.', first['messages'][0]['content'])
        self.assertEqual(FakeBrowser.seen[-1], ('open', {'url': 'https://dynolab.dev'}))
        self.assertIn('[1] link “Docs”', BrowsingModel.seen[1]['messages'][-1]['content'])

    def test_a_refused_step_tells_the_model_why(self):
        text, line = webaccess.browse('browser_click', {'element': 3})
        self.assertEqual(text, "That didn't work: The browser is in read-only mode")
        self.assertIn('refused', line)

    def test_no_app_no_browser_tools(self):
        self.file.unlink()
        self.assertIsNone(webaccess.browser_status())
        request = webaccess.with_web({'messages': [{'role': 'user', 'content': 'hi'}]}, webaccess.browser_status())
        self.assertEqual([t['function']['name'] for t in request['tools']], ['web_search', 'read_page'])
        self.assertTrue(webaccess.browse('browser_open', {'url': 'https://x.org'})[0].startswith('The browser is not available'))

    def test_a_wrong_token_is_not_a_browser(self):
        self.file.write_text(json.dumps({'port': self.browser.server_address[1], 'token': 'stale'}))
        self.assertIsNone(webaccess.browser_status())


if __name__ == '__main__':
    unittest.main()
