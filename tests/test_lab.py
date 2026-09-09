import json
from pathlib import Path
import tempfile
import unittest
from dyno.lab.server import Jobs, validate


class LabTests(unittest.TestCase):
    def test_invalid_settings_fail_before_loading_model(self):
        for config in [{}, {'operation':'exec','model':'m'}, {'operation':'inspect','model':'m','layers':[-1]},
                       {'operation':'inspect','model':'m','max_tokens':10000}]:
            with self.assertRaises(ValueError): validate(config)

    def test_restart_marks_interrupted_and_ids_cannot_escape_store(self):
        with tempfile.TemporaryDirectory() as root:
            folder=Path(root)/('a'*32);folder.mkdir()
            (folder/'job.json').write_text(json.dumps(dict(id='a'*32,status='running',created=0)))
            jobs=Jobs(root)
            self.assertEqual(jobs.read('a'*32)['status'],'interrupted')
            for identifier in ('../x','/tmp','a'*33):
                with self.assertRaises(FileNotFoundError): jobs.read(identifier)
            self.assertEqual(jobs.list()[0]['status'],'interrupted')
            jobs._directory_lock.close()


    def test_sdk_http_roundtrip_and_artifact(self):
        import threading
        from http.server import ThreadingHTTPServer
        from dyno.lab.server import Handler
        from dyno.sdk import Lab
        with tempfile.TemporaryDirectory() as root:
            jobs=Jobs(root)
            folder=Path(root)/('b'*32);folder.mkdir()
            (folder/'weights.npz').write_bytes(b'test-weights')
            jobs.write(folder/'job.json',dict(id='b'*32,status='completed',created=0,result={'artifacts':['weights.npz']}))
            server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.jobs=jobs
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                client=Lab('http://127.0.0.1:'+str(server.server_port))
                self.assertIn('probe',client.health()['operations'])
                self.assertEqual(client.wait('b'*32)['status'],'completed')
                target=Path(root)/'download.npz'
                client.artifact('b'*32,'weights.npz',target)
                self.assertEqual(target.read_bytes(),b'test-weights')
            finally:
                server.shutdown();server.server_close();thread.join();jobs._directory_lock.close()
