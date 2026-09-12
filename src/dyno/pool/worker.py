"""Desktop worker lifecycle, independent of the GUI and MLX."""
from __future__ import annotations

from collections import deque
import csv
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

from .node import command
from .runtime import LLAMA_REVISION, clean_env, terminate


def run_hidden(args, **kwargs):
    if sys.platform == 'win32':
        kwargs['creationflags'] = subprocess.CREATE_NO_WINDOW
    return subprocess.run(args, **kwargs)


def gpu_inventory():
    result = run_hidden([
        'nvidia-smi', '--query-gpu=index,name,memory.total,memory.used,utilization.gpu,temperature.gpu,driver_version',
        '--format=csv,noheader,nounits',
    ], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise ValueError(result.stderr.strip() or 'NVIDIA driver could not report GPU status')
    return parse_gpus(result.stdout)


def parse_gpus(output):
    result = []
    for row in csv.reader(io.StringIO(output)):
        if len(row) != 7:
            continue
        index, name, total, used, utilization, temperature, driver = [v.strip() for v in row]
        if not index.isdigit():
            continue
        def number(value):
            try:
                return int(value)
            except ValueError:
                return None
        result.append(dict(device='CUDA' + index, name=name, total_mib=number(total),
                           used_mib=number(used), utilization=number(utilization),
                           temperature=number(temperature), driver=driver))
    return result


def bundle_root():
    if getattr(sys, 'frozen', False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parents[3] / 'worker' / 'windows'


def bundled_binary():
    return bundle_root() / 'runtime' / 'ggml-rpc-server.exe'


def verify_runtime(binary):
    """Verify every bundled runtime file against the build manifest before execution."""
    import hashlib
    binary = Path(binary).resolve()
    manifest_path = binary.parent / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('revision') != LLAMA_REVISION:
        raise ValueError('Worker runtime does not match the Dyno pool version')
    files = manifest.get('files', {})
    if binary.name not in files or not files:
        raise ValueError('Runtime manifest is missing the worker executable')
    for name, expected in files.items():
        if Path(name).name != name or '/' in name or '\\' in name:
            raise ValueError('Invalid runtime manifest path')
        digest = hashlib.sha256()
        with (binary.parent / name).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest().lower() != expected.lower():
            raise ValueError('Runtime integrity check failed: ' + name)
    return binary


class Worker:
    """Own one worker process; never adopt or terminate someone else's listener."""
    def __init__(self):
        self.process = None
        self.state = 'Stopped'
        self.error = ''
        self.started = None
        self.logs = deque(maxlen=2000)
        self.lock = threading.RLock()
        self.stopping = False
        self.job = None

    def log(self, line):
        with self.lock:
            self.logs.append(line.rstrip()[:4000])

    def snapshot(self):
        with self.lock:
            return dict(state=self.state, error=self.error, pid=self.process.pid if self.process else None,
                        uptime_seconds=int(time.monotonic() - self.started) if self.started else 0,
                        logs=list(self.logs))

    def start(self, binary, device='CUDA0', port=50052):
        with self.lock:
            if self.state in ('Starting', 'Listening', 'Stopping'):
                raise ValueError('Worker is already running or changing state')
            if self.job:
                self.job.close()
                self.job = None
            self.state = 'Starting'
            self.error = ''
            self.stopping = False
        try:
            cmd = command(verify_runtime(binary), device, port)
            with socket.socket() as probe:
                if sys.platform == 'win32':
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                else:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(('127.0.0.1', port))
            kwargs = {'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}
            with self.lock:
                if self.stopping:
                    self.state = 'Stopped'
                    return
                env = clean_env()
                env.pop('CUDA_VISIBLE_DEVICES', None)
                env['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
                self.process = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', **kwargs)
                if sys.platform == 'win32':
                    from .windows_job import Job
                    self.job = Job()
                    try:
                        self.job.assign(self.process)
                    except OSError as exc:
                        if self.process.poll() is not None:
                            raise ValueError('GPU worker exited during startup; see the runtime log') from exc
                        raise
                self.started = time.monotonic()
                process = self.process
            self.reader = threading.Thread(target=self._read, args=(process,), daemon=True)
            self.reader.start()
            # TCP readiness alone is not proof of a paired Mac or model allocation.
            deadline = time.monotonic() + 30
            while process.poll() is None and not self.stopping:
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2):
                        with self.lock:
                            if not self.stopping:
                                self.state = 'Listening'
                        return
                except OSError:
                    if time.monotonic() >= deadline:
                        raise ValueError('GPU worker did not become ready within 30 seconds')
                    time.sleep(.1)
            if not self.stopping:
                raise ValueError('GPU worker exited during startup; see the runtime log')
        except Exception as exc:
            terminate(self.process)
            # Assignment can fail before the log reader has been started.
            reader = getattr(self, 'reader', None)
            if self.process and (reader is None or not reader.is_alive()):
                if self.process.stdout and not self.process.stdout.closed:
                    self.log(self.process.stdout.read())
                    self.process.stdout.close()
            if self.job:
                self.job.close()
                self.job = None
            with self.lock:
                self.state = 'Stopped' if self.stopping else 'Failed'
                self.error = '' if self.stopping else str(exc)
                self.started = None
            self.log(str(exc))
            if not self.stopping:
                raise

    def _read(self, process):
        try:
            for line in process.stdout:
                self.log(line)
            code = process.wait()
            with self.lock:
                if self.process is process and not self.stopping:
                    self.state = 'Failed'
                    self.error = f'Worker exited ({code}); see the runtime log'
                    self.started = None
        finally:
            process.stdout.close()

    def stop(self):
        with self.lock:
            self.stopping = True
            self.state = 'Stopping'
            process = self.process
        terminate(process)
        if self.job:
            self.job.close()
            self.job = None
        reader = getattr(self, 'reader', None)
        if reader and reader is not threading.current_thread():
            reader.join(timeout=2)
        with self.lock:
            self.state = 'Stopped'
            self.started = None
            self.process = None
        self.log('Stopped this worker. Any active pool request using it was interrupted.')
