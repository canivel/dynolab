"""Line-delimited JSON bridge for native coordinator interfaces (no Tk dependency)."""
import argparse
import json
from pathlib import Path
import select
import signal
import sys

from .discovery import discover, local_interfaces, peer_on_lan, safe_label
from .pairing import new_identity, pair, save_pair, store_root
from .runtime import check_route, pairing_record


def emit(event, **values):
    print(json.dumps(dict(event=event, **values)), flush=True)


def saved_workers(root=None):
    root = Path(root) if root is not None else store_root()
    records = {}
    for directory in sorted(root.glob('*'), key=lambda p: p.stat().st_mtime):
        if not directory.is_dir() or directory.is_symlink():
            continue
        try:
            record = pairing_record(directory.name, root=root)
            label = json.loads((directory / 'label.json').read_text()) if (directory / 'label.json').exists() else {}
            host = (directory / 'known_hosts').read_text().split()
            if len(host) != 3:
                continue
            identity = (record['peer'], record['local_address'], record['user'], host[1], host[2])
            previous = records.get(identity, {})
            aliases = previous.get('previous_pairing_ids', []) + ([previous['pairing_id']] if previous else [])
            records[identity] = dict(record, name=safe_label(label.get('name', 'Saved worker')),
                                    gpu=safe_label(label.get('gpu', '')), previous_pairing_ids=aliases)

        except (OSError, ValueError, KeyError, TypeError):
            continue
    return list(records.values())


def selected_interface(address):
    interface = next((i for i in local_interfaces() if i['address'] == address), None)
    if not interface:
        raise ValueError('Selected LAN interface is unavailable. Refresh networks and try again.')
    return interface


def verify_peer(address, local_address):
    interface = selected_interface(local_address)
    if not peer_on_lan(address, interface):
        raise ValueError('Worker must be on the selected directly connected private LAN.')
    if sys.platform == 'darwin':
        check_route(dict(peer=address, interface=interface['interface']))


def confirm(code):
    emit('verification_required', code=code)
    # Native UI must return an explicit decision for this exact transcript.
    readable, _, _ = select.select([sys.stdin], [], [], 110)
    if not readable:
        return False
    line = sys.stdin.buffer.readline(4097)
    if len(line) > 4096:
        return False
    try:
        response = json.loads(line)
        return response == {'confirm': True, 'code': code}
    except ValueError:
        return False


def pair_worker(address, port, local_address, name='', gpu='', confirmation=confirm):
    verify_peer(address, local_address)
    directory, public = new_identity()
    try:
        result = pair(address, port, local_address, public, confirmation)
        # A network change during either user's confirmation invalidates the attempt.
        verify_peer(address, local_address)
        record = save_pair(directory, address, local_address, result)
        (directory / 'label.json').write_text(json.dumps(dict(name=safe_label(name), gpu=safe_label(gpu))))
        return record
    except BaseException:
        # Remove only the dedicated files created for this attempt, never shared SSH files.
        for filename in ('identity', 'known_hosts', 'connection.json', 'label.json'):
            (directory / filename).unlink(missing_ok=True)
        directory.rmdir()
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(prog='dyno pool nearby')
    parser.add_argument('operation', choices=['inventory', 'scan', 'pair'])
    parser.add_argument('--local-address')
    parser.add_argument('--peer')
    parser.add_argument('--pair-port', type=int, default=50053)
    parser.add_argument('--name', default='Worker')
    parser.add_argument('--gpu', default='')
    args = parser.parse_args(argv)
    def stop(*_):
        raise KeyboardInterrupt
    old = signal.signal(signal.SIGTERM, stop)
    try:
        if args.operation == 'inventory':
            emit('inventory', interfaces=local_interfaces(), workers=saved_workers())
        elif args.operation == 'scan':
            emit('nearby', workers=discover([selected_interface(args.local_address)]))
        else:
            if not 1 <= args.pair_port <= 65535:
                raise ValueError('Invalid pairing port')
            record = pair_worker(args.peer, args.pair_port, args.local_address, args.name, args.gpu)
            emit('paired', connection=record, workers=saved_workers())
        return 0
    except KeyboardInterrupt:
        emit('cancelled', message='Pairing cancelled. No new local trust was retained.')
        return 1
    except Exception as exc:
        emit('error', message=str(exc))
        return 1
    finally:
        signal.signal(signal.SIGTERM, old)
