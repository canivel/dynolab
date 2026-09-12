import json
import io
from unittest.mock import Mock
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from dyno.pool import coordinator as c
from dyno.pool import pairing as p
from dyno.pool import runtime as r


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = patch.object(Path, 'home', return_value=self.root)
        self.home.start()
        self.addCleanup(self.home.stop)
        self.interface = dict(address='192.168.40.10', network='192.168.40.0/24', interface='en0')

    def save(self, peer='192.168.40.20'):
        folder, key = p.new_identity()
        record = p.save_pair(folder, peer, self.interface['address'], dict(user='worker', host_key=key, revision=r.LLAMA_REVISION))
        return folder, record

    def test_multiple_saved_workers_keep_distinct_trust(self):
        first, one = self.save()
        second, two = self.save('192.168.40.21')
        self.assertNotEqual(one['pairing_id'], two['pairing_id'])
        self.assertEqual(len(c.saved_workers()), 2)
        for directory, record in [(first, one), (second, two)]:
            args = r.ssh_args(record, 50200)
            self.assertIn(str(directory / 'identity'), args)
            self.assertIn('StrictHostKeyChecking=yes', args)
            self.assertIn('IdentityAgent=none', args)
            self.assertIn('GlobalKnownHostsFile=/dev/null', args)
        self.assertFalse((self.root / '.ssh').exists())

    def test_repeat_pairing_groups_same_verified_host_without_deleting_trust(self):
        first, one = self.save()
        second, two = self.save()
        # Different verified host keys are distinct even at the same address.
        self.assertEqual(len(c.saved_workers()), 2)
        (second / 'known_hosts').write_text((first / 'known_hosts').read_text())
        workers = c.saved_workers()
        self.assertEqual(len(workers), 1)
        self.assertEqual(workers[0]['pairing_id'], two['pairing_id'])
        self.assertIn(one['pairing_id'], workers[0]['previous_pairing_ids'])
        self.assertTrue((first / 'identity').exists())

    def test_tampered_or_missing_saved_connection_rejected(self):
        directory, record = self.save()
        for changes in [dict(local_address='192.168.40.11'), dict(peer='192.168.40.22'), dict(user='other'), dict(rpc_port=1234)]:
            with self.assertRaises(ValueError):
                r.ssh_args(record | changes, 50200)
        (directory / 'identity').unlink()
        self.assertEqual(c.saved_workers(), [])
        with self.assertRaises(ValueError):
            r.ssh_args(record, 50200)

    def test_rejected_attempt_cleans_new_identity_only(self):
        old, record = self.save()
        with patch.object(c, 'verify_peer'), patch.object(c, 'pair', side_effect=ValueError('Rejected')):
            with self.assertRaises(ValueError):
                c.pair_worker('192.168.40.21', 50053, self.interface['address'])
        self.assertEqual([d.name for d in p.store_root().iterdir()], [old.name])
        self.assertTrue((old / 'identity').exists())

    def test_network_change_after_confirmation_does_not_save_trust(self):
        _, key = p.new_identity(self.root / 'fixture')
        with patch.object(c, 'verify_peer', side_effect=[None, ValueError('LAN changed')]), \
             patch.object(c, 'pair', return_value=dict(user='worker', host_key=key, revision=r.LLAMA_REVISION)):
            with self.assertRaisesRegex(ValueError, 'LAN changed'):
                c.pair_worker('192.168.40.21', 50053, self.interface['address'])
        self.assertEqual(list(p.store_root().iterdir()), [])

    def test_only_selected_lan_can_pair(self):
        with patch.object(c, 'local_interfaces', return_value=[self.interface]), patch.object(c, 'check_route') as route:
            for peer in ('192.168.41.20', '8.8.8.8', '127.0.0.1'):
                with self.assertRaises(ValueError):
                    c.verify_peer(peer, self.interface['address'])
            route.assert_not_called()
            c.verify_peer('192.168.40.20', self.interface['address'])

    def test_scan_is_scoped_to_selected_interface(self):
        with patch.object(c, 'local_interfaces', return_value=[self.interface, dict(address='10.0.0.2', network='10.0.0.0/24', interface='en1')]), \
             patch.object(c, 'discover', return_value=[]) as discover, patch.object(c, 'emit'):
            self.assertEqual(c.main(['scan', '--local-address', self.interface['address']]), 0)
            discover.assert_called_once_with([self.interface])

    def test_confirmation_requires_the_full_current_code(self):
        code = 'ABCD 1234 ABCD 1234 ABCD 1234 ABCD 1234'
        for reply, expected in [(dict(confirm=True, code=code), True),
                                (dict(confirm=True, code='ABCD'), False),
                                (dict(confirm=False, code=code), False)]:
            stdin = Mock(buffer=io.BytesIO(json.dumps(reply).encode() + b'\n'))
            with patch.object(c.sys, 'stdin', stdin), patch.object(c.select, 'select', return_value=([stdin], [], [])), patch.object(c, 'emit'):
                self.assertEqual(c.confirm(code), expected)


if __name__ == '__main__':
    unittest.main()
