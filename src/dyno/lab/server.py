"""Research jobs run serially in disposable processes, separate from inference."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..execution import ExecutionHTTPMixin

OPERATIONS = ('inspect', 'compare', 'probe', 'sae')


def validate(body):
    if not isinstance(body, dict) or body.get('operation') not in OPERATIONS:
        raise ValueError('operation must be inspect, compare, probe or sae')
    if not isinstance(body.get('model'), str) or not body['model'].strip():
        raise ValueError('Choose a local model directory or Hugging Face model ID')
    if not isinstance(body.get('layers', [0]), list) or not 1 <= len(body.get('layers', [0])) <= 8:
        raise ValueError('Select between 1 and 8 layers')
    if any(type(i) is not int or not 0 <= i < 256 for i in body.get('layers', [0])):
        raise ValueError('Layer indices must be integers between 0 and 255')
    for key, default, maximum in [('max_tokens', 32, 128), ('max_input_tokens', 256, 1024), ('seed', 0, 2147483647)]:
        value = body.get(key, default)
        if type(value) is not int or not (0 if key == 'seed' else 1) <= value <= maximum:
            raise ValueError(f'{key} is out of range')
    if len(body.get('examples', [])) > 512:
        raise ValueError('At most 512 examples per experiment')
    if len(json.dumps(body)) > 500_000:
        raise ValueError('Experiment configuration is too large')
    return body


class Jobs:
    def __init__(self, root):
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        import fcntl
        self._directory_lock = (self.root / '.lock').open('a')
        try:
            fcntl.flock(self._directory_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._directory_lock.close()
            raise RuntimeError('Another Lab service is already using this data directory')
        self.lock = threading.RLock()
        self.active = None
        self.process = None
        # A interrupted app/service must not leave jobs permanently running.
        for path in self.root.glob('*/job.json'):
            try:
                data = json.loads(path.read_text())
                if data['status'] in ('queued', 'running'):
                    data.update(status='interrupted', ended=time.time())
                    self.write(path, data)
            except (OSError, ValueError, KeyError):
                pass

    @staticmethod
    def write(path, data):
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        os.chmod(temp, 0o600)
        temp.replace(path)

    def read(self, identifier):
        if len(identifier) != 32 or any(c not in '0123456789abcdef' for c in identifier):
            raise FileNotFoundError(identifier)
        return json.loads((self.root / identifier / 'job.json').read_text())

    def list(self):
        results = []
        for p in self.root.glob('*/job.json'):
            try:
                data = json.loads(p.read_text())
                results.append({k: v for k, v in data.items() if k not in ('result', 'config')})
            except (OSError, ValueError):
                pass
        return sorted(results, key=lambda x: x['created'], reverse=True)[:100]

    def submit(self, config):
        config = validate(config)
        with self.lock:
            if self.active:
                raise RuntimeError('A research job is already running. Cancel it or wait.')
            identifier = uuid.uuid4().hex
            folder = self.root / identifier
            folder.mkdir(mode=0o700)
            data = dict(id=identifier, created=time.time(), status='queued', operation=config['operation'], model=config['model'], config=config)
            self.write(folder / 'job.json', data)
            self.active = identifier
            threading.Thread(target=self.run, args=(data, folder), daemon=True).start()
            return data

    def run(self, data, folder):
        try:
            with self.lock:
                if self.active != data['id']:
                    return
                data['status'] = 'running'
                self.write(folder / 'job.json', data)
                env = dict(os.environ, PYTHONUNBUFFERED='1')
                with (folder / 'worker.log').open('w') as log:
                    self.process = subprocess.Popen([sys.executable, '-m', 'dyno.lab.worker', str(folder)], env=env, stdout=log, stderr=log)
                process = self.process
            process.wait(timeout=1800)
            with self.lock:
                if self.active != data['id']:
                    return
                result_path = folder / 'result.json'
                if process.returncode == 0 and result_path.exists():
                    data.update(status='completed', result=json.loads(result_path.read_text()))
                else:
                    data.update(status='failed', error=(folder / 'worker.log').read_text()[-4000:])
        except Exception as error:
            with self.lock:
                if self.active != data['id']:
                    return
                if self.process and self.process.poll() is None:
                    self.process.kill()
                    self.process.wait()
                data.update(status='failed', error=str(error))
        finally:
            with self.lock:
                if self.active == data['id']:
                    data['ended'] = time.time()
                    self.write(folder / 'job.json', data)
                    self.active = self.process = None

    def cancel(self, identifier):
        with self.lock:
            data = self.read(identifier)
            if self.active == identifier:
                if self.process:
                    self.process.kill()
                    self.process.wait()
                self.active = self.process = None
                data.update(status='cancelled', ended=time.time())
                self.write(self.root / identifier / 'job.json', data)
            return data


class Handler(ExecutionHTTPMixin, BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if not self._execution_local():
            return
        path = self.path.split('?', 1)[0]
        if path == '/lab/v1/health':
            self._execution_send({'status': 'ok', 'api_version': 1, 'worker_revision': 2, 'operations': OPERATIONS})
        elif path == '/lab/v1/jobs':
            self._execution_send({'jobs': self.server.jobs.list()})
        elif path == '/lab/v1/openapi.json':
            self._execution_send(json.loads(Path(__file__).with_name('openapi.json').read_text()))
        elif '/artifacts/' in path and path.startswith('/lab/v1/jobs/'):
            try:
                pieces = path.split('/')
                if len(pieces) != 7:
                    raise FileNotFoundError()
                job = self.server.jobs.read(pieces[4])
                name = pieces[6]
                if name not in job.get('result', {}).get('artifacts', []):
                    raise FileNotFoundError()
                content = (self.server.jobs.root / job['id'] / name).read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(content)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(content)
            except (OSError, ValueError):
                self._execution_send({'error': 'artifact not found'}, 404)
        elif path.startswith('/lab/v1/jobs/'):
            try:
                self._execution_send(self.server.jobs.read(path.rsplit('/', 1)[-1]))
            except (OSError, ValueError):
                self._execution_send({'error': 'job not found'}, 404)
        else:
            self._execution_send({'error': 'not found'}, 404)

    def do_DELETE(self):
        if not self._execution_local():
            return
        path = self.path.split('?', 1)[0]
        if not path.startswith('/lab/v1/jobs/'):
            self._execution_send({'error': 'not found'}, 404)
            return
        try:
            import shutil
            with self.server.jobs.lock:
                job = self.server.jobs.read(path.rsplit('/', 1)[-1])
                if self.server.jobs.active == job['id']:
                    self._execution_send({'error': 'cancel active job before deleting'}, 409)
                    return
                shutil.rmtree(self.server.jobs.root / job['id'])
            self._execution_send({'deleted': True})
        except (OSError, ValueError):
            self._execution_send({'error': 'job not found'}, 404)

    def do_POST(self):
        if not self._execution_local():
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 500_000:
                raise ValueError('Request must be 1–500000 bytes')
            body = json.loads(self.rfile.read(length))
            if self.path == '/lab/v1/jobs':
                self._execution_send(self.server.jobs.submit(body), 202)
            elif self.path.startswith('/lab/v1/jobs/') and self.path.endswith('/cancel'):
                self._execution_send(self.server.jobs.cancel(self.path.split('/')[-2]))
            else:
                self._execution_send({'error': 'not found'}, 404)
        except RuntimeError as error:
            self._execution_send({'error': str(error)}, 409)
        except (ValueError, TypeError, OSError) as error:
            self._execution_send({'error': str(error)}, 400)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Dyno local AI safety and alignment research API')
    parser.add_argument('--port', type=int, default=8980)
    parser.add_argument('--data-dir', default='~/.mlx-dyno/lab')
    args = parser.parse_args(argv)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.jobs = Jobs(args.data_dir)
    print(f'Dyno Research Lab: http://127.0.0.1:{args.port}/lab/v1', flush=True)
    def terminate(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, terminate)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if server.jobs.active:
            server.jobs.cancel(server.jobs.active)
        server.server_close()
        server.jobs._directory_lock.close()
    return 0
