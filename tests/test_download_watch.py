import tempfile
import unittest
from pathlib import Path
from dyno.download_watch import measure


class DownloadWatchTests(unittest.TestCase):
    def test_completed_and_partial_files_are_not_double_counted(self):
        with tempfile.TemporaryDirectory() as folder:
            self.check_measure(Path(folder))

    def check_measure(self, tmp_path):
        manifest = {'files': [{'name': 'a.gguf', 'bytes': 8}, {'name': 'b.gguf', 'bytes': 8192}]}
        (tmp_path / 'a.gguf').write_bytes(b'GGUF1234')
        cache = tmp_path / '.cache/huggingface/download'
        cache.mkdir(parents=True)
        partial = cache / 'b.incomplete'
        partial.write_bytes(b'x' * 4096)
        (cache / 'metadata').write_bytes(b'x' * 4096)
        downloaded, total, complete = measure(tmp_path, manifest)
        assert downloaded == min(8 + partial.stat().st_blocks * 512, 8200)
        assert total == 8200
        assert complete == 1
        partial.unlink()
        (tmp_path / 'b.gguf').write_bytes(b'x' * 8192)
        assert measure(tmp_path, manifest) == (8200, 8200, 2)


class DownloadControlTests(unittest.TestCase):
    def test_pause_continue_cancel_and_identity_check(self):
        import subprocess, sys, time, signal, os
        from dyno.download_watch import apply_control, process_identity
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            identity = process_identity(child.pid)
            self.assertFalse(apply_control(child.pid, 'different process', {'token':'a','action':'cancel'}, 'a'))
            self.assertFalse(apply_control(child.pid, identity, {'token':'wrong','action':'cancel'}, 'a'))
            self.assertTrue(apply_control(child.pid, identity, {'token':'a','action':'pause'}, 'a'))
            time.sleep(.1)
            state = subprocess.check_output(['/bin/ps','-p',str(child.pid),'-o','stat='],text=True)
            self.assertIn('T',state)
            self.assertTrue(apply_control(child.pid, identity, {'token':'a','action':'continue'}, 'a'))
            time.sleep(.1)
            self.assertNotIn('T', subprocess.check_output(['/bin/ps','-p',str(child.pid),'-o','stat='],text=True))
            self.assertTrue(apply_control(child.pid, identity, {'token':'a','action':'pause'}, 'a'))
            self.assertTrue(apply_control(child.pid, identity, {'token':'a','action':'cancel'}, 'a'))
            child.wait(timeout=5)
            self.assertNotEqual(child.returncode,0)
        finally:
            if child.poll() is None:
                os.kill(child.pid, signal.SIGCONT); child.kill(); child.wait()
