import json
import os
import stat
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from dyno import launch as L

from test_anthropic import Handler


def fake_model(root, repo, files=('model.safetensors',), config=None):
    folder = root / ('models--' + repo.replace('/', '--'))
    snap, blobs = folder / 'snapshots' / 'abc', folder / 'blobs'
    snap.mkdir(parents=True); blobs.mkdir(exist_ok=True)
    (snap / 'config.json').write_text(json.dumps(config or {'max_position_embeddings': 40960, 'quantization': {'bits': 4}}))
    for name in files:
        blob = blobs / name
        blob.write_bytes(b'x' * 1000)
        (snap / name).symlink_to(blob)
    return folder


class Models(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        fake_model(self.root, 'mlx-community/Qwen3-8B-4bit')
        fake_model(self.root, 'lmstudio-community/Qwen3.8-27B-MLX-4bit', config={'text_config': {'max_position_embeddings': 262144}})
        unfinished = fake_model(self.root, 'mlx-community/Llama-4-bit')
        (unfinished / 'blobs' / 'x.incomplete').write_text('')
        (self.root / 'models--nothing--here' / 'snapshots' / 'a').mkdir(parents=True)
        # A DFlash2 drafter: weights and a config like a model, but it can't be served alone.
        fake_model(self.root, 'z-lab/Qwen3.8-27B-DFlash2', config={'architectures': ['DFlash2DraftModel'], 'model_type': 'qwen3',
                                                                   'dflash_config': {'block_size': 8}})

    def tearDown(self): self.tmp.cleanup()

    def test_only_complete_downloads_with_their_context(self):
        found = {m['id']: m for m in L.downloaded(self.root)}
        self.assertEqual(sorted(found), ['lmstudio-community/Qwen3.8-27B-MLX-4bit', 'mlx-community/Qwen3-8B-4bit'])
        self.assertEqual(found['lmstudio-community/Qwen3.8-27B-MLX-4bit']['context'], 262144)
        self.assertEqual(found['mlx-community/Qwen3-8B-4bit']['bytes'], 1000)

    def test_a_model_by_a_piece_of_its_name(self):
        models = L.downloaded(self.root)
        self.assertEqual([m['id'] for m in L.resolve('qwen3.8-27b', models)], ['lmstudio-community/Qwen3.8-27B-MLX-4bit'])
        self.assertEqual([m['id'] for m in L.resolve('Qwen3-8B', models)], ['mlx-community/Qwen3-8B-4bit'])
        self.assertEqual(len(L.resolve('qwen', models)), 2)
        self.assertEqual(L.resolve('mistral', models), [])
        self.assertEqual(L.repo_of('/x/hub/models--a--b/snapshots/1'), 'a/b')


    def test_serve_refuses_a_drafter_and_names_its_model(self):
        _drafter_refusal = L.drafter_refusal
        drafter = self.root / 'models--z-lab--Qwen3.8-27B-DFlash2' / 'snapshots' / 'abc'
        refusal = _drafter_refusal(['--model', str(drafter), '--port', '8080'])
        self.assertIn('draft model for speculative decoding, not a model to serve', refusal)
        self.assertIn('Serve a Qwen3.8-27B model instead', refusal)
        self.assertIsNone(_drafter_refusal([f"--model={self.root / 'models--mlx-community--Qwen3-8B-4bit' / 'snapshots' / 'abc'}"]))
        self.assertIsNone(_drafter_refusal(['--port', '8080']))
        with mock.patch.dict(os.environ, {'HF_HUB_CACHE': str(self.root)}):
            self.assertIn('draft model for speculative decoding, not a model to serve', _drafter_refusal(['--model', 'z-lab/Qwen3.8-27B-DFlash2']))


class ClaudeEnv(unittest.TestCase):
    def test_points_claude_code_at_the_local_server_only(self):
        env, args = L.claude_env(8971, {'id': 'lmstudio-community/Qwen3.8-27B-MLX-4bit', 'context': 262144},
                           {'ANTHROPIC_API_KEY': 'sk-real', 'PATH': '/bin'})
        self.assertNotIn('ANTHROPIC_API_KEY', env)
        self.assertEqual(env['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:8971')
        self.assertEqual(env['ANTHROPIC_MODEL'], 'Qwen3.8-27B-MLX-4bit')
        self.assertEqual(env['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'Qwen3.8-27B-MLX-4bit')
        self.assertEqual(env['CLAUDE_CODE_MAX_CONTEXT_TOKENS'], '262144')
        self.assertEqual(env['PATH'], '/bin')
        self.assertEqual(env['API_TIMEOUT_MS'], '3600000')  # a slow Mac reads a big prompt for over 10 minutes
        self.assertEqual(args, [])
        own, _ = L.claude_env(8971, {'id': 'a/b'}, {'API_TIMEOUT_MS': '5000'})
        self.assertEqual(own['API_TIMEOUT_MS'], '5000')

    def test_codex_gets_a_dyno_provider_on_the_responses_api(self):
        env, args = L.codex_args(8971, {'id': 'mlx-community/Qwen3-8B-4bit', 'context': 40960}, {'PATH': '/bin'})
        options = dict(args[i + 1].split('=', 1) for i in range(0, len(args) - 2, 2))
        self.assertEqual(options['model_providers.dyno.base_url'], '"http://127.0.0.1:8971/v1"')
        self.assertEqual(options['model_providers.dyno.wire_api'], '"responses"')
        self.assertEqual(options['model_providers.dyno.requires_openai_auth'], 'false')
        self.assertEqual(options['model_context_window'], '40960')
        self.assertEqual(options['model_providers.dyno.stream_idle_timeout_ms'], '3600000')
        self.assertEqual(args[-2:], ['-m', 'Qwen3-8B-4bit'])


class Launch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); root = Path(self.tmp.name)
        fake_model(root / 'hub', 'mlx-community/Qwen3-8B-4bit')
        bin_dir = root / 'bin'; bin_dir.mkdir()
        self.seen = root / 'seen.json'
        claude = bin_dir / 'claude'
        claude.write_text(f'#!/bin/sh\npython3 -c "import json,os,sys; json.dump(dict(args=sys.argv[1:], env=dict(os.environ)), open(\'{self.seen}\',\'w\'))" "$@"\nexit 3\n')
        claude.chmod(claude.stat().st_mode | stat.S_IEXEC)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.env = mock.patch.dict(os.environ, HF_HUB_CACHE=str(root / 'hub'), PATH=f"{bin_dir}:{os.environ['PATH']}")
        self.env.start()

    def tearDown(self):
        self.env.stop(); self.server.shutdown(); self.server.server_close(); self.tmp.cleanup()

    def test_runs_claude_on_the_named_server_with_its_arguments(self):
        port = self.server.server_address[1]
        code = L.launch(['claude', '--model', 'qwen3-8b', '--port', str(port), '--', '-p', 'hello'])
        seen = json.loads(self.seen.read_text())
        self.assertEqual(code, 3)  # the tool's own exit code
        self.assertEqual(seen['args'], ['-p', 'hello'])
        self.assertEqual(seen['env']['ANTHROPIC_BASE_URL'], f'http://127.0.0.1:{port}')
        self.assertEqual(seen['env']['ANTHROPIC_MODEL'], 'Qwen3-8B-4bit')

    def test_a_server_it_started_is_stopped_when_the_terminal_closes(self):
        import signal, subprocess as sp
        server = mock.MagicMock()
        def hang_up(*a, **k): os.kill(os.getpid(), signal.SIGHUP)
        with mock.patch.object(L, 'serving', return_value=[]), mock.patch.object(L, '_free_port', return_value=8979), \
                mock.patch.object(L, '_start_server', return_value=(server, Path('log'))), mock.patch.object(L, '_wait'), \
                mock.patch.object(L, 'warm_up'), \
                mock.patch.object(sp, 'call', side_effect=hang_up):
            with self.assertRaises(SystemExit): L.launch(['claude', '--model', 'qwen3-8b'])
        server.terminate.assert_called_once()
        self.assertIs(signal.getsignal(signal.SIGHUP), signal.SIG_DFL)

    def test_a_started_server_runs_serve_only_with_the_chosen_thinking(self):
        with mock.patch.object(L.subprocess, 'Popen') as popen, mock.patch.object(Path, 'home', return_value=Path(self.tmp.name)):
            L._start_server(dict(id='m'), 8979, [], 'serve', False)
            command = popen.call_args[0][0]
            self.assertEqual(command[command.index('--mode') + 1], 'serve')
            self.assertEqual(command[command.index('--chat-template-args') + 1], '{"enable_thinking": false}')
            L._start_server(dict(id='m'), 8979, ['--mode', 'research'], 'serve')
            command = popen.call_args[0][0]
            self.assertEqual(command.count('--mode'), 1)
            self.assertNotIn('--chat-template-args', command)

    def test_says_how_fast_the_server_can_go(self):
        log = Path(self.tmp.name) / 'launch.log'
        log.write_text('Speculative decoding off: no MTP head for this model (pass --mtp-head)\n')
        with mock.patch.object(L, '_get', return_value={'mode': 'serve', 'model': {'loaded_at': None}, 'speculative': {'mode': None}}):
            self.assertEqual(L.speed_report(1), [])  # not loaded yet: the drafter isn't chosen
        with mock.patch.object(L, '_get', return_value={'mode': 'serve', 'model': {'loaded_at': 1}, 'speculative': {'mode': 'dflash'}}):
            self.assertEqual(L.speed_report(1), ['Speculative decoding: on (DFlash2 draft model).'])
        with mock.patch.object(L, '_get', return_value={'mode': 'research', 'model': {'loaded_at': 1}, 'speculative': {'mode': None}}):
            lines = L.speed_report(1, log)
        self.assertIn('off (no MTP head for this model (pass --mtp-head))', lines[0])
        self.assertIn('research mode', lines[1])

    def test_clear_refusals(self):
        self.assertEqual(L.launch(['claude', '--model', 'mistral', '--port', '1']), 1)
        with mock.patch.object(L, 'speaks_anthropic', return_value=False):
            self.assertEqual(L.launch(['claude', '--model', 'qwen3-8b', '--port', '1']), 1)
        self.assertFalse(self.seen.exists())


if __name__ == '__main__':
    unittest.main()
