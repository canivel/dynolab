import json
import os
import stat
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from dyno.lab.websearch import WebSearch, _check_public, _readable


class FakeSearch:
    """Answers /healthz and /search?format=json the way SearXNG does."""
    def __init__(self):
        self.queries = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                if self.path.startswith('/healthz'):
                    body = b'OK'
                else:
                    outer.queries.append(self.path)
                    body = json.dumps(dict(results=[
                        dict(title='A GHOST in <b>Long-Horizon</b> Agents', url='https://arxiv.org/abs/2610.02664', content='Agents forget rules.'),
                        dict(title='Duplicate', url='https://arxiv.org/abs/2610.02664', content='same link'),
                        dict(title='Not a web link', url='javascript:alert(1)', content='skipped'),
                        dict(title='Second', url='https://example.org/b', content='b'),
                    ])).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self): self.server.shutdown(); self.server.server_close()


class WebSearchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake = FakeSearch()

    def tearDown(self):
        self.fake.close(); self.tmp.cleanup()

    def test_search_returns_clean_unique_web_results(self):
        web = WebSearch(Path(self.tmp.name), port=self.fake.port)
        r = web.search('  ghost   long horizon ', limit=5)
        self.assertEqual(r['query'], 'ghost long horizon')
        self.assertEqual([x['url'] for x in r['results']], ['https://arxiv.org/abs/2610.02664', 'https://example.org/b'])
        self.assertEqual(r['results'][0]['title'], 'A GHOST in Long-Horizon Agents')
        self.assertIn('format=json', self.fake.queries[0])
        with self.assertRaises(ValueError): web.search('')
        with self.assertRaises(ValueError): WebSearch(Path(self.tmp.name), port=1).search('x')  # not running

    def test_only_public_pages_can_be_read(self):
        for url in ['http://127.0.0.1:8980/lab/v1/health', 'http://localhost:8971/v1/models', 'http://10.0.0.5/', 'http://192.168.1.1/',
                    'http://169.254.169.254/latest/meta-data/', 'http://[::1]/', 'file:///etc/passwd', 'ftp://example.org/x']:
            with self.assertRaises(ValueError, msg=url): _check_public(url)

    def test_page_text_leaves_out_scripts_and_navigation(self):
        title, text = _readable('<html><head><title>Paper</title><style>p{}</style></head><body><nav>Menu</nav>'
                                '<h1>Results</h1><p>The rate was 11.5%.</p><script>steal()</script><footer>Footer</footer></body></html>')
        self.assertEqual(title, 'Paper')
        self.assertIn('The rate was 11.5%.', text)
        for gone in ('Menu', 'steal', 'Footer', 'p{}'): self.assertNotIn(gone, text)

    def test_start_runs_the_pinned_image_on_this_mac_only(self):
        log = Path(self.tmp.name) / 'docker.log'
        docker = Path(self.tmp.name) / 'docker'
        docker.write_text(f'#!/bin/sh\necho "$@" >> {log}\nexit 0\n')
        docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
        web = WebSearch(Path(self.tmp.name) / 'lab', port=self.fake.port, docker=str(docker))
        self.fake.close()  # not answering until the container "starts"
        self.fake = FakeSearch(); web.port = self.fake.port
        web._healthy = lambda timeout=2.0: log.exists() and 'run' in log.read_text()
        self.assertEqual(web.start()['status'], 'starting')
        end = time.time() + 10
        while web.status()['status'] == 'starting' and time.time() < end: time.sleep(0.05)
        self.assertEqual(web.status()['status'], 'running', web.status())
        calls = log.read_text()
        self.assertIn('pull searxng/searxng@sha256:', calls)
        self.assertIn(f'-p 127.0.0.1:{web.port}:8080', calls)  # never on the network
        settings = (Path(self.tmp.name) / 'lab' / 'websearch' / 'searxng' / 'settings.yml').read_text()
        self.assertIn('formats: [html, json]', settings)
        self.assertEqual(web.stop()['status'], 'off')

    def test_a_clear_error_when_docker_is_not_running(self):
        docker = Path(self.tmp.name) / 'docker'
        docker.write_text('#!/bin/sh\nexit 1\n'); docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
        web = WebSearch(Path(self.tmp.name) / 'lab', port=1, docker=str(docker))
        web.start()
        end = time.time() + 10
        while web.status()['status'] == 'starting' and time.time() < end: time.sleep(0.05)
        self.assertEqual(web.status()['status'], 'error')
        self.assertIn("Docker isn't running", web.status()['error'])


if __name__ == '__main__':
    unittest.main()
