"""Real MLX hybrid-decoder regression tests; skipped on hosts without MLX."""
import unittest
try:
    import mlx.core as mx
    from mlx_lm.models.qwen3_5 import TextModel, TextModelArgs, Model, ModelArgs
except ImportError:
    mx = None
from dyno.lab.worker import tap_layer


@unittest.skipIf(mx is None, 'MLX runtime required')
class HybridTapTests(unittest.TestCase):
    def test_hybrid_metadata_cache_and_noop_logits(self):
        mx.random.seed(7)
        model = TextModel(TextModelArgs(hidden_size=64, intermediate_size=128,
            num_hidden_layers=4, num_attention_heads=4, num_key_value_heads=2,
            vocab_size=128, head_dim=16, linear_num_value_heads=4,
            linear_num_key_heads=2, linear_key_head_dim=16, linear_value_head_dim=16,
            full_attention_interval=4))
        tokens = mx.array([[1, 2, 3, 4]])
        baseline = model(tokens)
        mx.eval(baseline)
        captured, active, collecting = {}, {}, [True]
        for i in (0, 3):
            model.layers[i] = tap_layer(model.layers[i], i, captured, active, collecting)
        self.assertTrue(model.layers[0].is_linear)
        self.assertFalse(model.layers[3].is_linear)
        self.assertEqual(len(model.make_cache()), 4)
        with self.assertRaises(AttributeError):
            _ = model.layers[0].does_not_exist
        observed = model(tokens)
        self.assertTrue(bool(mx.allclose(baseline, observed)))
        self.assertEqual(captured[0].shape, (1, 4, 64))
        self.assertEqual(captured[3].shape, (1, 4, 64))
        active[3] = lambda value: value * 0
        changed = model(tokens)
        self.assertFalse(bool(mx.allclose(observed, changed)))
        active.clear()
        self.assertTrue(bool(mx.allclose(baseline, model(tokens))))

    def test_all_experiment_methods_on_hybrid_decoder(self):
        """Exercise the real worker and hybrid math with a small random model.

        The loader/tokenizer fixture avoids downloading large weights. This is
        an integration regression, not an evaluation of model quality.
        """
        import json
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        from dyno.lab.worker import run

        class Tokenizer:
            eos_token_id = 127
            eos_token_ids = {127}
            def encode(self, text, **kwargs):
                return [1 + sum(map(ord, word)) % 125 for word in text.split()]
            def decode(self, tokens):
                return ' '.join(f'token-{i}' for i in tokens)

        def load(*args, **kwargs):
            model = TextModel(TextModelArgs(hidden_size=64, intermediate_size=128,
                num_hidden_layers=4, num_attention_heads=4, num_key_value_heads=2,
                vocab_size=128, head_dim=16, linear_num_value_heads=4,
                linear_num_key_heads=2, linear_key_head_dim=16, linear_value_head_dim=16,
                full_attention_interval=4))
            from dataclasses import asdict
            outer = Model(ModelArgs(model_type='qwen3_5', text_config=asdict(model.args)))
            return outer, Tokenizer(), {'model_type': 'qwen3_5'}

        examples = [dict(text=f'example number {i}', label=i % 2,
            split='train' if i < 4 else 'test') for i in range(8)]
        configs = [
            dict(operation='inspect', prompt='A small example', layers=[0, 3]),
            dict(operation='compare', prompt='A small example', layers=[0], strengths=[1], max_tokens=2),
            dict(operation='patch_sweep', prompt='B small example', clean_prompt='A small example', target_token='yes', foil_token='no', layers=[3], positions=[2]),
            dict(operation='patch_sweep', prompt='A small example', clean_prompt='A small example', target_token='yes', foil_token='no', layers=[0,3], positions=[0,2]),
            dict(operation='sae', examples=examples, layers=[0], features=8, steps=2, sae_architecture='topk', top_k=2),
            dict(operation='probe', examples=examples, layers=[0]),
            dict(operation='sae', examples=examples, layers=[0], features=8, steps=2),
        ]
        for config in configs:
            with self.subTest(operation=config['operation']), tempfile.TemporaryDirectory() as root:
                with patch('mlx_lm.load', side_effect=load):
                    run(dict(config, model=root), Path(root))
                result = json.loads((Path(root) / 'result.json').read_text())
                if config['operation'] == 'inspect':
                    self.assertEqual(len(result['layers'][0]['norms']), 3)
                    self.assertIn('predictions', result['layers'][0])
                elif config['operation'] == 'compare':
                    self.assertEqual(result['trials'][0]['delta'], 0)
                    self.assertEqual(result['trials'][0]['baseline'], result['trials'][0]['output'])
                elif config['operation'] == 'patch_sweep':
                    if config['prompt'] == config['clean_prompt']:
                        self.assertEqual(len(result['patches']), 4)
                        self.assertTrue(all(abs(p['delta']) < 1e-6 and p['recovery'] is None for p in result['patches']))
                    else:
                        self.assertAlmostEqual(result['patches'][0]['patched_logit_difference'], result['clean_logit_difference'], places=5)
                    self.assertAlmostEqual(result['restored_control_logit_difference'], result['corrupted_logit_difference'])
                else:
                    if config.get('sae_architecture') == 'topk':
                        self.assertLessEqual(result['reports'][0]['mean_active'], 2)
                    self.assertTrue(result['reports'])
                    self.assertTrue(result['artifacts'])
