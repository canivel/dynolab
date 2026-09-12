"""Run explicitly against a built Windows package; never stop another listener.

Usage: python worker/windows/smoke-test.py <app/DynoWorker>
This tests the real CUDA runtime, not cross-machine inference or GUI clicks.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'src'))
from dyno.pool.worker import Worker, gpu_inventory, verify_runtime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('Run on native Windows')
    binary = verify_runtime(args.app / 'runtime' / 'ggml-rpc-server.exe')
    # Do not accidentally satisfy missing packaged DLLs from the build toolkit.
    os.environ['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
    for name in list(os.environ):
        if name.startswith('CUDA_PATH'):
            del os.environ[name]
    gpus = gpu_inventory()
    assert any(gpu['device'] == 'CUDA0' for gpu in gpus), gpus
    worker = Worker()
    results = []
    try:
        for cycle in range(2):
            worker.start(binary)
            assert worker.snapshot()['state'] == 'Listening'
            time.sleep(1)
            assert worker.process.poll() is None
            assert any('CUDA0' in line for line in worker.snapshot()['logs'])
            results.append({'cycle': cycle + 1, 'listening': worker.snapshot()})
            process = worker.process
            worker.stop()
            assert process.poll() is not None
            assert worker.snapshot()['state'] == 'Stopped'

        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            listener.bind(('127.0.0.1', 50052))
            listener.listen()
            try:
                worker.start(binary)
                raise AssertionError('Occupied port was accepted')
            except OSError:
                pass
            assert worker.process is None
            with socket.create_connection(('127.0.0.1', 50052), timeout=1):
                pass
            results.append({'occupied_port': 'rejected; test listener survived'})

        try:
            worker.start(binary, device='CUDA999')
            raise AssertionError('Unavailable CUDA device was accepted')
        except ValueError:
            assert worker.snapshot()['state'] == 'Failed'
            results.append({'startup_error': worker.snapshot()})
    finally:
        worker.stop()
    output = Path('windows-smoke-results.json').resolve()
    output.write_text(json.dumps({'gpus': gpus, 'results': results}, indent=2), encoding='utf-8')
    print(f'PASS: CUDA lifecycle, restart, port protection and startup error. Results: {output}')


if __name__ == '__main__':
    main()
