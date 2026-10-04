import tempfile
import unittest
from pathlib import Path
from dyno.lab.compatibility import fingerprint, compare_contracts, require_compatible

class CompatibilityTests(unittest.TestCase):
    def test_unknown_never_passes_and_dimensions_block(self):
        self.assertFalse(compare_contracts({}, {})['allowed'])
        with self.assertRaises(ValueError):require_compatible({}, {})
        a={k:'known' for k in ('revision','architecture','quantization','tokenizer_sha256','model_config_sha256','hook','layer','pooling','dimension','normalization','backend')}
        self.assertTrue(require_compatible(a,a)['allowed'])
        self.assertEqual(compare_contracts(a,dict(a,layer=9))['status'],'mismatch')
        b=dict(a,dimension=123)
        self.assertEqual(compare_contracts(a,b)['status'],'mismatch')
    def test_snapshot_and_tokenizer_change(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'snapshots'/('a'*40);p.mkdir(parents=True);(p/'tokenizer.json').write_text('{}')
            a=fingerprint(p,dict(model_type='test',quantization={'bits':4}),16,layer=8)
            self.assertEqual(a['revision'],'a'*40);self.assertTrue(compare_contracts(a,a)['allowed'])
            (p/'tokenizer.json').write_text('{"changed":true}')
            b=fingerprint(p,dict(model_type='test',quantization={'bits':4}),16,layer=8)
            self.assertEqual(compare_contracts(a,b)['status'],'mismatch')
            self.assertIsNone(fingerprint(Path(folder),{},16)['revision'])
