import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from dyno.pool import runtime as p
from dyno.pool.node import command


class PoolTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.binary=Path(self.tmp.name)/'server'; self.binary.write_text('#!/bin/sh\n'); self.binary.chmod(0o700)
        self.model=Path(self.tmp.name)/'model.gguf'; self.model.write_bytes(b'GGUFtest')
        self.inventory=[dict(interface='en0',address='192.168.40.10',network='192.168.40.0/24')]
        self.config=dict(binary=str(self.binary),model=str(self.model),local_address='192.168.40.10',peer='192.168.40.20',user='researcher')
    def valid(self): return p.validate(self.config,self.inventory)
    def test_private_does_not_mean_same_lan(self):
        for peer in ['8.8.8.8','127.0.0.1','169.254.1.1','192.168.41.20','192.168.40.0','192.168.40.255','192.168.40.10','localhost','::1']:
            with self.subTest(peer=peer),self.assertRaises(ValueError):
                p.validate(dict(self.config,peer=peer),self.inventory)
    def test_inactive_and_vpn_interfaces_ignored(self):
        text='en0: flags=UP\n inet 192.168.40.10 netmask 0xffffff00\n status: active\nutun0: flags=UP\n inet 10.0.0.2 netmask 0xffffff00\n status: active\nen1: flags=UP\n inet 192.168.2.2 netmask 0xffffff00\n status: inactive\n'
        self.assertEqual(p.interfaces(text),self.inventory)
    def test_route_must_stay_direct_and_selected(self):
        for route in ['interface: utun0','interface: en1','gateway: 192.168.40.1\ninterface: en0']:
            with patch.object(p.subprocess,'check_output',return_value=route),self.assertRaises(ValueError): p.check_route(self.valid())
        with patch.object(p.subprocess,'check_output',return_value='gateway: aa:bb:cc:dd:ee:ff\ninterface: en0'): p.check_route(self.valid())
    def test_unknown_and_invalid_settings_fail(self):
        for extra in [dict(ssh_port=True),dict(context=0),dict(context=999999),dict(user='-oProxyCommand=bad'),dict(alias='../model'),dict(host='0.0.0.0')]:
            with self.subTest(extra=extra),self.assertRaises(ValueError): p.validate(dict(self.config,**extra),self.inventory)
    def test_mlx_weights_not_accepted(self):
        self.model.write_bytes(b'OTHER')
        with self.assertRaises(ValueError): self.valid()
    def test_ssh_has_no_remote_command_or_proxy(self):
        a=p.ssh_args(self.valid(),50001)
        self.assertIn('StrictHostKeyChecking=yes',a); self.assertIn('ForwardAgent=no',a)
        self.assertIn('/dev/null',a); self.assertIn('127.0.0.1:50001:127.0.0.1:50052',a)
        self.assertEqual(a[-1],'researcher@192.168.40.20'); self.assertIn('-N',a)
    def test_coordinator_loopback_and_worker_loopback(self):
        a=p.server_args(self.valid(),50001)
        self.assertEqual(a[a.index('--host')+1],'127.0.0.1')
        self.assertEqual(a[a.index('--rpc')+1],'127.0.0.1:50001')
        n=command(self.binary,'CUDA0',50052)
        self.assertEqual(n[n.index('--host')+1],'127.0.0.1')
        with self.assertRaises(ValueError): command(self.binary,'CUDA0 --host 0.0.0.0',50052)
    def test_plan_never_starts_process(self):
        with patch.object(p,'lan_interfaces',return_value=self.inventory),patch.object(p,'check_route'),patch.object(p,'check_binary'),patch.object(p.subprocess,'Popen') as popen:
            plan=p.plan(self.config)
            self.assertIsNone(plan['memory_estimate']); self.assertEqual(plan['status'],'plan_only'); popen.assert_not_called()
    def test_environment_cannot_override_binding(self):
        with patch.dict(p.os.environ,{'LLAMA_ARG_HOST':'0.0.0.0','GGML_RPC_DEBUG':'1'}):
            env=p.clean_env(); self.assertNotIn('LLAMA_ARG_HOST',env); self.assertNotIn('GGML_RPC_DEBUG',env); self.assertEqual(env['GGML_RPC_NO_RDMA'],'1')
    def test_stop_targets_owned_process_only(self):
        process=Mock(); process.poll.return_value=None
        p.terminate(process); process.terminate.assert_called_once(); process.wait.assert_called_once(); process.kill.assert_not_called()
    def test_failed_tunnel_is_reaped(self):
        process=Mock(); process.poll.return_value=1
        with patch.object(p,'lan_interfaces',return_value=self.inventory),patch.object(p,'check_route'),patch.object(p,'check_binary'),patch.object(p.subprocess,'Popen',return_value=process),patch.object(p,'terminate') as reap:
            with self.assertRaisesRegex(ValueError,'SSH failed'): p.run(self.config)
            self.assertEqual(reap.call_args_list[-1].args,(process,))

    def test_device_probe_requires_both_accelerators(self):
        text='  MTL0: Mac (100 MiB, 90 MiB free)\n  RPC0: remote (200 MiB, 180 MiB free)'
        self.assertEqual(p.discovered_memory(text),{'MTL0':90,'RPC0':180})
        with self.assertRaises(ValueError): p.discovered_memory('  MTL0: Mac (100 MiB, 90 MiB free)')
