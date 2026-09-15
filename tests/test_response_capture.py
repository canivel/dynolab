import unittest
try:
    import numpy as np
except ImportError:
    np = None
from dyno.lab.response_capture import response_tokens, summarize_response
from dyno.lab.server import validate


class ResponseCaptureTests(unittest.TestCase):
    @unittest.skipIf(np is None, 'NumPy required for activation arithmetic')
    def test_response_excludes_prompt_and_weights_tokens_equally(self):
        states = np.array([[100, 200], [2, 4], [6, 8]], dtype=np.float32)
        result = summarize_response(states, 1)
        np.testing.assert_array_equal(result['response_mean'], [4, 6])
        np.testing.assert_array_equal(result['prompt_mean'], [100, 200])
        np.testing.assert_array_equal(result['prompt_last'], [100, 200])
        for boundary in (0, 3):
            with self.assertRaises(ValueError):
                summarize_response(states, boundary)
        with self.assertRaises(ValueError):
            summarize_response([[1], [float('nan')]], 1)

    def test_token_boundary_and_limit_are_checked(self):
        class Tokenizer:
            def encode(self, text):
                return list(text.encode())
        self.assertEqual(response_tokens(Tokenizer(), 'p:', 'yes', 5), ([112,58,121,101,115], 2))
        with self.assertRaises(ValueError):
            response_tokens(Tokenizer(), 'p:', 'yes', 4)
        class MergingTokenizer:
            def encode(self, text):
                return [1] if text == 'p' else [2, 3]
        with self.assertRaises(ValueError):
            response_tokens(MergingTokenizer(), 'p', 'yes', 10)
        with self.assertRaises(ValueError):
            response_tokens(Tokenizer(), 'p', '', 10)

    def test_api_rejects_response_for_other_methods(self):
        for operation in ('compare', 'probe', 'sae', 'patch_sweep'):
            with self.assertRaises(ValueError):
                validate(dict(operation=operation, model='test', response='answer'))
        validate(dict(operation='inspect', model='test', response='answer'))
