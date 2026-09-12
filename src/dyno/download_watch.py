"""Publish progress for an existing manifest-based Hub download, without owning it.

Run with --root, --pid and --id. Controls are opt-in and bound to the original process identity. Partial bytes
are allocated disk blocks, so they are explicitly an estimate, not wire bytes.
"""
import argparse
import json
import os
import time
import signal
import subprocess
import uuid
from pathlib import Path


def measure(root, manifest):
    total = sum(item['bytes'] for item in manifest['files'])
    complete = 0
    downloaded = 0
    for item in manifest['files']:
        path = root / item['name']
        if path.is_file() and path.stat().st_size == item['bytes']:
            complete += 1
            downloaded += item['bytes']
    cache = root / '.cache' / 'huggingface' / 'download'
    if cache.exists():
        downloaded += sum(p.stat().st_blocks * 512 for p in cache.rglob('*.incomplete') if p.is_file())
    return min(downloaded, total), total, complete


def process_identity(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=', '-o', 'command='], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def apply_control(pid, identity, command, token):
    if not isinstance(command, dict):
        return False
    if command.get('token') != token or not identity or process_identity(pid) != identity:
        return False
    action = command.get('action')
    if action == 'pause':
        os.kill(pid, signal.SIGSTOP)
    elif action == 'continue':
        os.kill(pid, signal.SIGCONT)
    elif action == 'cancel':
        os.kill(pid, signal.SIGTERM)
        # A stopped process must run to handle termination and release locks.
        os.kill(pid, signal.SIGCONT)
    else:
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--id', required=True)
    parser.add_argument('--control', action='store_true', help='Allow pause/continue/cancel of this specific process')
    args = parser.parse_args()
    if not args.id.replace('-', '').replace('_', '').isalnum():
        parser.error('id must contain only letters, digits, dashes and underscores')
    manifest = json.loads((args.root / 'download-manifest.json').read_text())
    directory = Path.home() / '.mlx-dyno' / 'downloads'
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / (args.id + '.json')
    identity = process_identity(args.pid)
    if not identity:
        raise RuntimeError('Download process is not running')
    token = uuid.uuid4().hex if args.control else None
    control = directory / (args.id + '.control')
    cancelled = False
    while True:
        if args.control and control.exists():
            try:
                command = json.loads(control.read_text()) if control.stat().st_size < 4096 else {}
                if apply_control(args.pid, identity, command, token) and command.get('action') == 'cancel':
                    cancelled = True
            except (OSError, ValueError):
                pass
            finally:
                control.unlink(missing_ok=True)
        downloaded, total, complete = measure(args.root, manifest)
        running = process_identity(args.pid) == identity
        proc_state = subprocess.run(['/bin/ps', '-p', str(args.pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip() if running else ''
        paused = 'T' in proc_state
        finished = complete == len(manifest['files'])
        state = 'complete' if finished else ('cancelled' if cancelled and (not running or 'Z' in proc_state) else ('paused' if paused else ('downloading' if running else 'interrupted')))
        if cancelled and state == 'downloading': state = 'cancelling'
        record = dict(repository=manifest['repository'], downloaded_bytes=downloaded,
                      total_bytes=total, updated_at=time.time(), state=state,
                      detail=f'{complete} of {len(manifest["files"])} files downloaded · disk estimate',
                      directory=str(args.root))
        if token and state in ('downloading', 'paused'):
            record['control_token'] = token
        if state == 'cancelled':
            record['detail'] = 'Cancelled · partial files kept on disk'
        if finished:
            record['detail'] = 'Files downloaded · preparation may still be required before use'
        temp = output.with_suffix('.tmp')
        temp.write_text(json.dumps(record)); temp.chmod(0o600); temp.replace(output)
        if finished or not running or state == 'cancelled':
            break
        time.sleep(2)


if __name__ == '__main__':
    main()
