import json
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from dyno import webaccess
from dyno.serve import gguf


def write_gguf(path, context=40960, arch='qwen3'):
    """A GGUF header: an array before the context length, as llama.cpp's converter writes them."""
    def string(text):
        data = text.encode()
        return struct.pack('<Q', len(data)) + data

    items = [string('general.architecture') + struct.pack('<I', 8) + string(arch),
             string('general.name') + struct.pack('<I', 8) + string('Qwen3 0.6B'),
             string('general.tags') + struct.pack('<IIQ', 9, 8, 2) + string('a') + string('bb'),
             string(f'{arch}.block_count') + struct.pack('<II', 4, 28),
             string(f'{arch}.context_length') + struct.pack('<II', 4, context)]
    with open(path, 'wb') as file:
        file.write(b'GGUF' + struct.pack('<IQQ', 3, 0, len(items)) + b''.join(items))


class FakeLlama(BaseHTTPRequestHandler):
    """llama-server: prompt progress chunks when asked, its alias as the model name, timings on the last chunk."""
    seen = []

    def log_message(self, *a): pass

    def reply(self, body, kind='application/json'):
        self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/props': return self.reply(json.dumps({'model_path': '/m.gguf', 'n_ctx': 4096}).encode())
        self.reply(b'{"status": "ok"}')

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        FakeLlama.seen.append(request)
        timings = {'cache_n': 4, 'prompt_n': 20, 'prompt_ms': 50.0, 'predicted_n': 2, 'predicted_ms': 20.0}
        base = {'model': gguf.BACKEND, 'object': 'chat.completion.chunk'}
        if not request.get('stream'):
            return self.reply(json.dumps({'model': gguf.BACKEND, 'choices': [{'message': {'role': 'assistant', 'content': 'Hi there'}, 'finish_reason': 'stop'}],
                                          'usage': {'prompt_tokens': 24, 'completion_tokens': 2}, 'timings': timings}).encode())
        chunks = []
        if request.get('return_progress'):
            chunks += [{**base, 'choices': [{'delta': {'role': 'assistant', 'content': None}}], 'prompt_progress': {'total': 24, 'cache': 4, 'processed': p}}
                       for p in (4, 24)]
        chunks += [{**base, 'choices': [{'delta': {'role': 'assistant', 'content': None}}]},
                   {**base, 'choices': [{'delta': {'content': 'Hi'}}]}, {**base, 'choices': [{'delta': {'content': ' there'}}]},
                   {**base, 'choices': [{'delta': {}, 'finish_reason': 'stop'}], 'timings': timings}]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for c in chunks: self.wfile.write(b'data: ' + json.dumps(c, separators=(',', ':')).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')


def frames(raw):
    return [json.loads(f.split('data: ', 1)[1]) for f in raw.decode().strip().split('\n\n') if f.startswith('data: {')]


class FrontEnd(unittest.TestCase):
    def setUp(self):
        FakeLlama.seen = []
        gguf.registry.__init__()
        self.llama = ThreadingHTTPServer(('127.0.0.1', 0), FakeLlama)
        threading.Thread(target=self.llama.serve_forever, daemon=True).start()
        patch = mock.patch.multiple(gguf.GGUFHandler, backend=f'http://127.0.0.1:{self.llama.server_address[1]}', model_path='/models/q.gguf')
        patch.start(); self.addCleanup(patch.stop)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), gguf.GGUFHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        quiet = mock.patch.object(gguf.activity, 'say')
        quiet.start(); self.addCleanup(quiet.stop)

    def tearDown(self):
        for server in (self.server, self.llama): server.shutdown(); server.server_close()

    def post(self, body, path='/v1/chat/completions'):
        request = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as response: return response.read()

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=10) as response: return json.loads(response.read())

    def test_a_streamed_chat_passes_through_timed_without_the_progress_it_asked_for(self):
        raw = self.post({'model': 'default_model', 'stream': True, 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertTrue(FakeLlama.seen[0]['return_progress'])
        chunks = frames(raw)
        self.assertFalse(any('prompt_progress' in c for c in chunks))
        self.assertEqual(sum(1 for c in chunks if c['choices'] and 'role' in c['choices'][0]['delta']), 1)
        self.assertEqual(''.join(c['choices'][0]['delta'].get('content') or '' for c in chunks), 'Hi there')
        self.assertEqual({c['model'] for c in chunks}, {'default_model'})
        self.assertTrue(raw.endswith(b'data: [DONE]\n\n'))
        stats = self.get('/stats')
        self.assertEqual(stats['totals'], {'requests': 1, 'requests_failed': 0, 'prompt_tokens': 24, 'cached_prompt_tokens': 4,
                                           'generated_tokens': 2, 'decode_seconds': stats['totals']['decode_seconds']})
        self.assertEqual(stats['recent_requests'][0]['finish_reason'], 'stop')

    def test_a_client_that_asks_for_progress_gets_it(self):
        chunks = frames(self.post({'stream': True, 'return_progress': True, 'messages': [{'role': 'user', 'content': 'hi'}]}))
        self.assertEqual(sum('prompt_progress' in c for c in chunks), 2)

    def test_a_whole_answer_is_timed_from_llama_cpps_timings(self):
        answer = json.loads(self.post({'model': 'mine', 'messages': [{'role': 'user', 'content': 'hi'}]}))
        self.assertEqual((answer['model'], answer['choices'][0]['message']['content']), ('mine', 'Hi there'))
        record = self.get('/stats')['recent_requests'][0]
        self.assertEqual((record['prompt_tokens'], record['completion_tokens'], record['queue_seconds']), (24, 2, 0.0))
        self.assertAlmostEqual(record['time_to_first_token'], 0.05, delta=0.02)

    def test_the_coding_tools_apis_and_dynos_endpoints(self):
        message = json.loads(self.post({'model': 'claude-sonnet', 'max_tokens': 50, 'messages': [{'role': 'user', 'content': 'hi'}]}, '/v1/messages'))
        self.assertEqual(message['content'], [{'type': 'text', 'text': 'Hi there'}])
        self.assertEqual(self.get('/v1/models')['data'][0]['id'], '/models/q.gguf')
        self.assertEqual(self.get('/health'), {'status': 'ok'})
        self.assertEqual(self.get('/props')['n_ctx'], 4096)  # forwarded: the app reads the context length here
        capabilities = self.get('/lab/capabilities')
        self.assertFalse(capabilities['serving_activations'])
        self.assertIn('llama.cpp', capabilities['reason'])
        self.assertEqual(self.get('/stats')['model']['path'], '/models/q.gguf')

    def test_web_access_runs_on_the_front_end(self):
        with mock.patch.object(gguf.CodingAPIsMixin, 'web_access', True), mock.patch.object(webaccess, 'browser_status', return_value=None):
            chunks = frames(self.post({'stream': True, 'messages': [{'role': 'user', 'content': 'news?'}]}))
        self.assertIn('web_search', [t['function']['name'] for t in FakeLlama.seen[0]['tools']])
        self.assertEqual(''.join(c['choices'][0]['delta'].get('content') or '' for c in chunks if c.get('choices')), 'Hi there')


class Arguments(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(); self.addCleanup(folder.cleanup)
        self.model = os.path.join(folder.name, 'q.gguf')

    def test_mlx_launch_options_become_llama_server_flags(self):
        write_gguf(self.model, context=40960)
        host, port, model, flags = gguf.llama_arguments(['--model', self.model, '--host', '127.0.0.1', '--port', '8971', '--log-level', 'WARNING',
            '--max-tokens', '4096', '--decode-concurrency', '1', '--temp=0.7', '--chat-template-args', '{"enable_thinking":false}'])
        self.assertEqual((host, port, model), ('127.0.0.1', 8971, self.model))
        joined = ' '.join(flags)
        for expected in ('--n-predict 4096', '--parallel 1', '--temp 0.7', '--chat-template-kwargs {"enable_thinking":false}', '--n-gpu-layers 999'):
            self.assertIn(expected, joined)
        self.assertNotIn('--ctx-size', flags)  # the model's own 40,960

    def test_a_long_context_is_capped_unless_asked_for(self):
        write_gguf(self.model, context=262144)
        self.assertIn('--ctx-size 65536', ' '.join(gguf.llama_arguments(['--model', self.model])[3]))
        self.assertIn('--parallel 1', ' '.join(gguf.llama_arguments(['--model', self.model])[3]))
        self.assertIn('--ctx-size 131072', ' '.join(gguf.llama_arguments(['--model', self.model, '--ctx-size', '131072'])[3]))

    def test_metadata_and_an_unknown_flag(self):
        write_gguf(self.model, context=8192, arch='llama')
        self.assertEqual(gguf.metadata(self.model), {'architecture': 'llama', 'name': 'Qwen3 0.6B', 'context_length': 8192})
        with self.assertRaises(SystemExit): gguf.llama_arguments(['--model', self.model, '--adapter-path', 'x'])
        self.assertTrue(gguf.is_gguf(['--model', '/a/B.GGUF']))
        self.assertFalse(gguf.is_gguf(['--model', 'mlx-community/Qwen3-8B-4bit']))


@unittest.skipIf(sys.platform == 'win32', 'the guard is for macOS')
class Guard(unittest.TestCase):
    def test_llama_server_stops_when_dyno_does(self):
        parent = subprocess.Popen([sys.executable, '-c', 'import subprocess, sys, time\n'
            'subprocess.Popen([sys.executable, "-m", "dyno.serve.gguf", "--guard", str(__import__("os").getpid()), "sleep", "61.4321"])\n'
            'time.sleep(1.5)'], env={**os.environ, 'PYTHONPATH': os.pathsep.join(sys.path)})
        time.sleep(1.0)
        sleeping = subprocess.run(['pgrep', '-f', 'sleep 61.4321'], capture_output=True, text=True).stdout.split()
        self.assertTrue(sleeping)
        parent.wait(timeout=10)
        for _ in range(20):
            alive = [pid for pid in sleeping if subprocess.run(['kill', '-0', pid], capture_output=True).returncode == 0]
            if not alive: break
            time.sleep(0.25)
        self.assertEqual(alive, [])


if __name__ == '__main__':
    unittest.main()
