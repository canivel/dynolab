import json
import io
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from dyno.pool import pairing as p
from dyno.pool.discovery import peer_on_lan, safe_label
from dyno.pool.runtime import LLAMA_REVISION, ssh_args, resolved_ssh_args
from dyno.pool.worker_setup import setup_request


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.directory, self.public = p.new_identity(self.folder.name)
        # Transport tests use loopback, without opening any LAN listener or SSH setting.
        self.validator = patch.object(p, 'setup_request', side_effect=lambda address, key:
                                      setup_request('192.168.50.2', key))
        self.validator.start()
        self.addCleanup(self.validator.stop)

    def server(self, confirm, install, **kwargs):
        server = p.PairingServer('127.0.0.1', 0, lambda peer: peer == '127.0.0.1', confirm, install, **kwargs)
        self.addCleanup(server.close)
        return server

    def result(self):
        return dict(user='worker', host_key=self.public, revision=LLAMA_REVISION)

    def test_real_tls_both_confirm_same_code_then_install(self):
        codes, calls = [], []
        def confirm(code, name, stop):
            codes.append(code)
            return True
        def install(request):
            calls.append(request)
            return self.result()
        server = self.server(confirm, install)
        result = p.pair('127.0.0.1', server.port, '127.0.0.1', self.public,
                        lambda code: codes.append(code) or True)
        self.assertEqual(result, self.result())
        self.assertEqual(len(codes), 2)
        self.assertEqual(codes[0], codes[1])
        self.assertEqual(len(codes[0].replace(' ', '')), 32)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['public_key'], self.public)

    def test_worker_rejection_never_installs(self):
        calls = []
        server = self.server(lambda *args: False, lambda request: calls.append(request))
        with self.assertRaises(ValueError):
            p.pair('127.0.0.1', server.port, '127.0.0.1', self.public, lambda code: True)
        self.assertEqual(calls, [])

    def test_coordinator_rejection_never_installs(self):
        calls = []
        server = self.server(lambda *args: True, lambda request: calls.append(request))
        with self.assertRaisesRegex(ValueError, 'cancelled'):
            p.pair('127.0.0.1', server.port, '127.0.0.1', self.public, lambda code: False)
        server.close()
        self.assertEqual(calls, [])

    def test_code_binds_certificate_public_key_and_challenge(self):
        hello = dict(public_key=self.public, nonce='a' * 64)
        code = p.verification_code(b'cert1', hello, {'nonce': 'b' * 64})
        self.assertNotEqual(code, p.verification_code(b'cert2', hello, {'nonce': 'b' * 64}))
        self.assertNotEqual(code, p.verification_code(b'cert1', hello | {'public_key': 'other'}, {'nonce': 'b' * 64}))
        self.assertNotEqual(code, p.verification_code(b'cert1', hello, {'nonce': 'c' * 64}))

    def test_malformed_requests_never_prompt_or_install(self):
        calls = []
        server = self.server(lambda *args: calls.append('confirm'), lambda request: calls.append('install'))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        for request in [dict(v=1), dict(v=1, revision='wrong', public_key=self.public,
                                      nonce='a'*64, name='test')]:
            with socket.create_connection(('127.0.0.1', server.port), timeout=2) as raw:
                with ctx.wrap_socket(raw, server_hostname='test') as conn:
                    conn.sendall(p.canonical(request) + b'\n')
                    self.assertEqual(conn.recv(1), b'')
        self.assertEqual(calls, [])

    def test_expired_server_stops(self):
        server = self.server(lambda *args: True, lambda request: self.fail('must not install'), lifetime=.05)
        self.assertTrue(server.stopped.wait(2))

    def test_unapproved_close_cancels_pending_request(self):
        prompted = threading.Event()
        calls = []
        def confirm(code, name, stop):
            prompted.set()
            stop.wait(3)
            return True
        server = self.server(confirm, lambda request: calls.append(request))
        def client():
            try:
                p.pair('127.0.0.1', server.port, '127.0.0.1', self.public, lambda code: True)
            except (ValueError, OSError):
                pass
        thread = threading.Thread(target=client)
        thread.start()
        self.assertTrue(prompted.wait(3))
        server.close()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(calls, [])

    def test_save_dedicated_trust_without_touching_other_files(self):
        other = Path(self.folder.name) / 'unrelated'
        other.write_text('retain')
        record = p.save_pair(self.directory, '192.168.50.3', '192.168.50.2', self.result())
        self.assertEqual(record['pairing_id'], self.directory.name)
        self.assertIn(self.public, (self.directory / 'known_hosts').read_text())
        self.assertEqual(other.read_text(), 'retain')
        self.assertTrue((self.directory / 'identity').exists())

    def test_private_direct_subnet_filter(self):
        interface = dict(address='192.168.50.2', network='192.168.50.0/24')
        self.assertTrue(peer_on_lan('192.168.50.3', interface))
        for address in ['192.168.50.2', '192.168.50.0', '192.168.50.255', '192.168.51.3', '8.8.8.8', '127.0.0.1']:
            self.assertFalse(peer_on_lan(address, interface))
        self.assertEqual(safe_label('worker\n\x00name'), 'workername')

    def test_pairing_preserves_verified_nondefault_ssh_endpoint(self):
        record = p.save_pair(self.directory, '192.168.50.3', '192.168.50.2', self.result() | {'ssh_port': 50054})
        self.assertEqual(record['ssh_port'], 50054)
        self.assertTrue((self.directory / 'known_hosts').read_text().startswith('[192.168.50.3]:50054 ssh-ed25519 '))
        for port in (True, '50054', 0, 65536):
            with self.assertRaisesRegex(ValueError, 'invalid SSH port'):
                p.save_pair(self.directory, '192.168.50.3', '192.168.50.2', self.result() | {'ssh_port': port})

    def test_saved_pairing_id_cannot_escape_store(self):
        with self.assertRaisesRegex(ValueError, 'identifier'):
            ssh_args({'pairing_id': '../anything'}, 50054)

    def test_runtime_uses_dedicated_identity_and_rejects_changed_peer(self):
        home = Path(self.folder.name) / 'coordinator home'
        directory, public = p.new_identity(home / '.dyno' / 'pairs')
        record = p.save_pair(directory, '192.168.50.3', '192.168.50.2', self.result())
        with patch('pathlib.Path.home', return_value=home):
            args = ssh_args(record, 50054)
            self.assertIn('StrictHostKeyChecking=yes', args)
            self.assertIn(str(directory / 'identity'), args)
            self.assertIn('UserKnownHostsFile="' + str(directory / 'known_hosts') + '"', args)
            with self.assertRaisesRegex(ValueError, 'does not match'):
                ssh_args(record | {'peer': '192.168.50.4'}, 50054)

    def test_legacy_endpoint_recovery_requires_existing_pinned_identity(self):
        import subprocess
        home = Path(self.folder.name) / 'coordinator'
        directory, public = p.new_identity(home / '.dyno' / 'pairs')
        record = p.save_pair(directory, '192.168.50.3', '192.168.50.2', self.result())
        before = (directory / 'known_hosts').read_bytes()
        with patch('pathlib.Path.home', return_value=home), patch('dyno.pool.runtime.subprocess.run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, '', '')
            args = resolved_ssh_args(record, 50100)
            self.assertEqual(args[args.index('-p') + 1], '50054')
            self.assertIn('HostKeyAlias=192.168.50.3', args)
            self.assertIn('StrictHostKeyChecking=yes', run.call_args.args[0])
            self.assertNotIn('-N', run.call_args.args[0])
            self.assertNotIn('-L', run.call_args.args[0])
            run.return_value = subprocess.CompletedProcess([], 255, '', 'Host key verification failed')
            args = resolved_ssh_args(record, 50100)
            self.assertEqual(args[args.index('-p') + 1], '22')
        self.assertEqual((directory / 'known_hosts').read_bytes(), before)
        self.assertEqual(json.loads((directory / 'connection.json').read_text())['ssh_port'], 22)

    def test_recovery_skips_new_pairings_and_manual_connections(self):
        home = Path(self.folder.name) / 'coordinator'
        directory, _ = p.new_identity(home / '.dyno' / 'pairs')
        record = p.save_pair(directory, '192.168.50.3', '192.168.50.2', self.result() | {'ssh_port': 50054})
        with patch('pathlib.Path.home', return_value=home), patch('dyno.pool.runtime.subprocess.run') as run:
            args = resolved_ssh_args(record, 50100)
            self.assertEqual(args[args.index('-p') + 1], '50054')
            self.assertIn('IdentityAgent=none', args)
            manual = record.copy(); del manual['pairing_id']
            self.assertEqual(resolved_ssh_args(manual, 50100), ssh_args(manual, 50100))
            run.assert_not_called()

    def test_oversized_and_deep_messages_rejected(self):
        for data in [b'x' * (p.LIMIT + 2), b'[' * 1200 + b']' * 1200 + b'\n']:
            with self.assertRaises(ValueError):
                p.receive(io.BytesIO(data))

    def test_occupied_pairing_port_is_preserved(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with self.assertRaises(OSError):
                p.PairingServer('127.0.0.1', listener.getsockname()[1], lambda peer: True,
                                lambda *args: True, lambda request: self.fail())
            with socket.create_connection(listener.getsockname(), timeout=1):
                pass

    def test_real_mdns_discovery_on_isolated_loopback(self):
        from dyno.pool.discovery import Advertisement, discover
        interface = dict(address='127.0.0.1', network='127.0.0.0/8')
        advertisement = Advertisement(interface, 'Dyno loopback test', 'Test GPU', 50053)
        try:
            # Production filtering forbids loopback; override only for this transport test.
            with patch('dyno.pool.discovery.peer_on_lan', side_effect=lambda address, iface: address == '127.0.0.1'):
                devices = discover([interface], seconds=2)
            self.assertTrue(any(d['name'] == 'Dyno loopback test' and d['port'] == 50053 for d in devices))
        finally:
            advertisement.close()


if __name__ == '__main__':
    unittest.main()
