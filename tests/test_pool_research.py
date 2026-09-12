import unittest
from unittest.mock import patch
from dyno.sdk import Lab
from dyno.lab.server import validate
from dyno.lab.pool_model import PoolModel, NoRedirect

class PoolResearchTests(unittest.TestCase):
    def test_sdk_preserves_operation_and_pool_connection(self):
        with patch.object(Lab, '_request', return_value={'id':'job'}) as request:
            Lab().submit_pool('probe','resident.gguf',pool_port=8978,layers=[4])
            self.assertEqual(request.call_args.args[1],dict(operation='probe',model='resident.gguf',backend='pool',pool_port=8978,layers=[4]))
    def test_invalid_ports_rejected(self):
        for port in [0,-1,65536,True,'8978']:
            with self.assertRaises(ValueError): PoolModel(dict(pool_port=port),{},{},[True])
    def test_pool_limits(self):
        base=dict(operation='probe',model='resident.gguf',backend='pool',pool_port=8978,layers=[4])
        self.assertEqual(validate(base),base)
        for extra in [dict(pool_port=True),dict(max_input_tokens=257),dict(layers=[0,1,2,3,4]),dict(backend='unknown')]:
            with self.assertRaises(ValueError): validate(dict(base,**extra))
    def test_redirects_rejected(self):
        with self.assertRaises(ValueError): NoRedirect().redirect_request(None,None,302,'',{},'https://example.com')
    def test_runtime_mismatch_fails_before_forward(self):
        with patch.object(PoolModel,'call',return_value=dict(dyno_capture_version=1,model_path='model')):
            with self.assertRaises(ValueError):
                PoolModel(dict(pool_port=8978,model='model'),{},{},[True])
