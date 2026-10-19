"""A model that reads a long prompt is silent for minutes: the stream must keep the client from giving up."""
import json
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from dyno import apis
from dyno.apis import CodingAPIsMixin


class SlowChat(BaseHTTPRequestHandler):
    """Answers after `delay` seconds, as a model does after reading its prompt; or refuses the request."""
    delay, status, finished = 0.0, 200, []

    def log_message(self, *a): pass

    def do_GET(self):
        body = b'{"data": []}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        if SlowChat.status != 200:
            body = b'{"error": "prompt too long"}'
            self.send_response(SlowChat.status); self.send_header('Content-Length', str(len(body))); self.end_headers()
            return self.wfile.write(body)
        time.sleep(SlowChat.delay)
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        try:
            for c in [{'choices': [{'delta': {'content': 'Fixed.'}, 'finish_reason': 'stop'}]},
                      {'choices': [], 'usage': {'prompt_tokens': 20000, 'completion_tokens': 2}}]:
                self.wfile.write(b'data: ' + json.dumps(c).encode() + b'\n\n'); self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n')
            SlowChat.finished.append(True)
        except (BrokenPipeError, ConnectionResetError):
            SlowChat.finished.append(False)


class Handler(CodingAPIsMixin, SlowChat):
    pass


def events(raw):
    return [json.loads(f.split('data: ', 1)[1]) for f in raw.decode().strip().split('\n\n')]


class KeepAlive(unittest.TestCase):
    def setUp(self):
        SlowChat.delay, SlowChat.status, SlowChat.finished = 0.0, 200, []
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        self.tick = mock.patch.object(apis, 'KEEPALIVE', 0.1)
        self.tick.start()

    def tearDown(self):
        self.tick.stop(); self.server.shutdown(); self.server.server_close()

    def post(self, path, body):
        return urllib.request.urlopen(urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                                             headers={'Content-Type': 'application/json'}), timeout=10)

    def test_claude_gets_pings_while_the_prompt_is_read(self):
        SlowChat.delay = 0.5
        with self.post('/v1/messages', {'model': 'x', 'max_tokens': 10, 'stream': True, 'messages': [{'role': 'user', 'content': 'fix'}]}) as r:
            ev = events(r.read())
        kinds = [e['type'] for e in ev]
        self.assertEqual(kinds[0], 'message_start')
        self.assertGreaterEqual(kinds.count('ping'), 2)
        self.assertEqual(kinds[-1], 'message_stop')
        self.assertEqual([e['delta']['text'] for e in ev if e['type'] == 'content_block_delta'], ['Fixed.'])
        self.assertEqual(kinds.count('message_start'), 1)

    def test_codex_gets_progress_events_while_the_prompt_is_read(self):
        SlowChat.delay = 0.5
        with self.post('/v1/responses', {'model': 'x', 'stream': True, 'input': 'fix'}) as r:
            ev = events(r.read())
        kinds = [e['type'] for e in ev]
        self.assertEqual(kinds[:2], ['response.created', 'response.in_progress'])
        self.assertGreaterEqual(kinds.count('response.in_progress'), 3)
        self.assertEqual(kinds[-1], 'response.completed')
        self.assertEqual([e['sequence_number'] for e in ev], list(range(len(ev))))

    def test_a_quick_refusal_keeps_its_status(self):
        SlowChat.status = 400
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post('/v1/messages', {'model': 'x', 'max_tokens': 10, 'stream': True, 'messages': [{'role': 'user', 'content': 'fix'}]})
        self.assertEqual(caught.exception.code, 400)
        self.assertIn('prompt too long', json.loads(caught.exception.read())['error']['message'])

    def test_a_client_that_leaves_closes_the_model_stream(self):
        SlowChat.delay = 0.4
        body = json.dumps({'model': 'x', 'max_tokens': 10, 'stream': True, 'messages': [{'role': 'user', 'content': 'fix'}]}).encode()
        client = socket.create_connection(self.server.server_address)
        client.sendall(b'POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
                       b'Content-Length: %d\r\n\r\n' % len(body) + body)
        self.assertIn(b'200', client.recv(100))
        client.close()  # gives up while the model is still reading
        deadline = time.time() + 5
        while not SlowChat.finished and time.time() < deadline: time.sleep(0.05)
        time.sleep(0.3)
        # The handler noticed and stopped relaying; no exception escaped (a server error would show in the next test).
        with self.post('/v1/messages', {'model': 'x', 'max_tokens': 10, 'stream': True, 'messages': [{'role': 'user', 'content': 'again'}]}) as r:
            self.assertEqual(events(r.read())[-1]['type'], 'message_stop')


if __name__ == '__main__':
    unittest.main()
