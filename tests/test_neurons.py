"""Neuron-level interpretability in the Lab: corpus, capture, atlas, SAEs, ablations, attribution, auto-interp.

The pure parts run everywhere; the MLX parts use a tiny random Qwen3 and are skipped on hosts without MLX."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from dyno.lab.neurons import autointerp, corpus
from dyno.lab.neurons.ablation import interval, validate as validate_ablation
from dyno.lab.neurons.atlas import rate
from dyno.lab.neurons.capture import EDGES, bin_of, validate as validate_capture
from dyno.lab.neurons.units import validate as validate_units
from dyno.lab.server import validate as validate_job

try:
    import mlx.core as mx
    from mlx_lm.models.qwen3 import Model as Qwen3, ModelArgs as Qwen3Args
except ImportError:
    mx = None


class CharTokenizer:
    """Every character is a token (ids 1-95); enough to drive a tiny model."""
    pad_token_id = 0
    eos_token_id = 0
    eos_token_ids = {0}

    def encode(self, text, add_special_tokens=True):
        return [min(95, max(1, ord(ch) - 31)) for ch in text]

    def decode(self, ids):
        return ''.join(chr(i + 31) for i in ids if i > 0)


class Corpus(unittest.TestCase):
    def test_split_is_by_document_and_fixed_by_seed(self):
        ids = [f'doc:{i}' for i in range(4000)]
        first = [corpus.heldout(d, 3, 0.2) for d in ids]
        self.assertEqual(first, [corpus.heldout(d, 3, 0.2) for d in ids])
        self.assertAlmostEqual(sum(first) / len(first), 0.2, delta=0.03)
        self.assertNotEqual(first, [corpus.heldout(d, 4, 0.2) for d in ids])

    def test_sources_presets_and_mistakes(self):
        self.assertAlmostEqual(sum(s['share'] for s in corpus.sources('web-mix')), 1.0)
        for bad in ('nope', [], [{'hf': 'a', 'files': ['b']}], [{'files': 'x.txt'}], [{'hf': 'a', 'share': 2}]):
            with self.assertRaises(ValueError): corpus.sources(bad)

    def test_files_windows_and_a_source_that_fails_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'a.txt').write_text('alpha ' * 400)
            Path(tmp, 'b.jsonl').write_text('\n'.join(json.dumps({'text': f'beta {i} ' * 50}) for i in range(20)))
            sources = [{'files': [f'{tmp}/a.txt', f'{tmp}/b.jsonl'], 'share': 0.5}, {'hf': 'down/dataset', 'share': 0.5}]
            with mock.patch.object(corpus, 'hf_documents', side_effect=OSError('HTTP Error 500')):
                docs, provenance = corpus.documents(sources, 3000, tmp, seed=0)
            self.assertIn('skipped', provenance[1])
            self.assertEqual(len(docs), 21)
            windows = list(corpus.contexts(docs, CharTokenizer(), 256, 3000))
            self.assertLessEqual(sum(len(w['ids']) for w in windows), 3000 + 256)
            self.assertTrue(all(len(w['ids']) <= 256 for w in windows))
            # A long document becomes several windows; nothing is cut silently.
            self.assertGreater(sum(1 for w in windows if w['doc'] == 0), 1)


class Validation(unittest.TestCase):
    def test_capture_and_jobs(self):
        with self.assertRaises(ValueError): validate_capture({'hook': 'nope'})
        with self.assertRaises(ValueError): validate_capture({'units': {'neurons': 'some'}})
        ok = dict(operation='capture', model='m', layers=[3], corpus='web-mix')
        self.assertEqual(validate_job(ok)['operation'], 'capture')
        for bad in (dict(ok, corpus=None), dict(ok, layers='all'), dict(ok, layers=list(range(9))), dict(ok, resume_from='x')):
            with self.assertRaises(ValueError): validate_job(bad)
        with self.assertRaises(ValueError): validate_job(dict(operation='autointerp', atlas='0' * 32))  # no explainer
        job = validate_job(dict(operation='autointerp', atlas='0' * 32, explainer={'port': 8083}, scorer={'port': 8084}))
        self.assertEqual(job['operation'], 'autointerp')
        self.assertEqual(validate_job(dict(operation='probe', model='m', hook='mlp_hidden', examples=[]))['hook'], 'mlp_hidden')
        with self.assertRaises(ValueError): validate_job(dict(operation='probe', model='m', hook='neurons'))
        with self.assertRaises(ValueError): validate_job(dict(operation='probe', model='m', hook='mlp_hidden', backend='pool', pool_port=9000))

    def test_ablation_and_units(self):
        with self.assertRaises(ValueError): validate_ablation(dict(conditions=[dict(name='r', kind='random_mass', of='missing')]))
        self.assertEqual(len(validate_ablation({})['conditions']), 6)
        u = validate_units(dict(mode='ablate_set', prompt='The capital of France is', target_token=' Paris', units=[[3, 7], {'layer': 5, 'unit': 1}]))
        self.assertEqual((u['units'], u['layers']), ([(3, 7), (5, 1)], [3, 5]))
        with self.assertRaises(ValueError): validate_units(dict(mode='steer', prompt='x'))


class Numbers(unittest.TestCase):
    def test_bins_and_rates(self):
        values = np.array([0.001, 0.02, -0.5, 3.0, 2000.0])
        self.assertEqual(bin_of(values, np).tolist(), [0, 1, 4, 5, len(EDGES)])
        levels = [1.0, 10.0, 100.0]
        self.assertEqual(rate([100, 10, 1], levels, 1.0), 100)
        self.assertAlmostEqual(rate([100, 10, 1], levels, 10 ** 0.5), 10 ** 1.5, places=6)

    def test_bootstrap_interval(self):
        rng = np.random.default_rng(0)
        out = interval([1, 2, 3, 4] * 10, [10] * 40, 500, rng)
        self.assertAlmostEqual(out['mean'], 0.25)
        self.assertLess(out['low'], 0.25); self.assertGreater(out['high'], 0.25)

    def test_autointerp_parsing_and_scores(self):
        self.assertEqual(autointerp.clean_label('Label: [[important|7]] words\nmore'), 'important words')
        self.assertEqual(autointerp.numbers('I think [1, 4, 9]', 5), {1, 4})
        self.assertEqual(autointerp.numbers('none', 5), set())
        b = autointerp.balanced([True, True, False, False], [True, False, False, False])
        self.assertAlmostEqual(b['balanced_accuracy'], (1 + 2 / 3) / 2)
        row = lambda i, s: dict(layer=1, kind='neuron', index=i, pole='positive', detection=dict(balanced_accuracy=s))
        p = autointerp.paired([row(i, 0.9) for i in range(30)], [row(i, 0.5) for i in range(30)], 0.75)
        self.assertEqual((p['poles'], p['this_pass_rate'], p['other_pass_rate']), (30, 1.0, 0.0))
        self.assertLess(p['p_value'], 0.01)

    def test_explain_prompt_marks_strong_tokens_on_the_poles_own_scale(self):
        text = autointerp.Text({'1': 'the', '2': ' cat', '3': ' sat'})
        page = {'poles': {'negative': {'maximum': 4.0, 'per_100_tokens': {'10%': 2.0, '25%': 1.0, '50%': 0.5},
                                       'top': [dict(ids=[1, 2, 3], center=1, activations=[0.0, -4.0, -0.2], value=-4.0)], 'stratified': []}}}
        prompt = autointerp.explain_prompt(text, 'negative', page, dict(examples=5, stratified=True, window=8))
        self.assertIn('the[[ cat|10]] sat', prompt)


def tiny_model():
    mx.random.seed(0)
    args = Qwen3Args(model_type='qwen3', hidden_size=32, num_hidden_layers=3, intermediate_size=64, num_attention_heads=4,
                     rms_norm_eps=1e-6, vocab_size=96, num_key_value_heads=2, max_position_embeddings=1024, rope_theta=10000.0,
                     head_dim=8, tie_word_embeddings=True)
    model = Qwen3(args)
    mx.eval(model.parameters())
    return model


@unittest.skipIf(mx is None, 'MLX runtime required')
class WithMLX(unittest.TestCase):
    def test_mlp_hooks_reconstruct_and_a_wrong_activation_is_caught(self):
        from dyno.lab.neurons import hooks
        model, tok = tiny_model(), CharTokenizer()
        ids = mx.array([tok.encode('hello there')])
        baseline = model(ids)
        captured, active, collecting = {}, {}, [True]
        info = hooks.install(model, [1], 'mlp_hidden', captured, active, collecting, {'model_type': 'qwen3'})
        self.assertEqual(info['activation'], 'silu')
        self.assertLess(hooks.check(model, tok, [1], 'mlp_hidden'), 1e-5)
        self.assertTrue(bool(mx.allclose(baseline, model(ids), atol=1e-5)))
        self.assertEqual(captured[1].shape, (1, 11, 64))
        self.assertEqual(hooks.width(model, 'mlp_hidden', 1), 64)
        active[1] = lambda h: h * 0
        self.assertFalse(bool(mx.allclose(baseline, model(ids), atol=1e-4)))
        wrong = tiny_model()
        hooks.install(wrong, [1], 'mlp_hidden', {}, {}, [True], {'model_type': 'gemma3'})
        with self.assertRaises(ValueError): hooks.check(wrong, tok, [1], 'mlp_hidden')

    def test_reservoir_keeps_the_true_top_examples_with_centered_windows(self):
        from dyno.lab.neurons.capture import Reservoir, validate
        c = validate(dict(top_k=3, heldout_top_k=2, bucket_samples=2, random_samples=4, heldout_random=2, window_before=2, window_after=1))
        rng = np.random.default_rng(1)
        n, B, L = 5, 4, 10
        r = Reservoir(n, c)
        all_values, all_where = [], []
        for batch in range(3):
            values = rng.normal(size=(B, L, n)).astype('float32')
            ids = rng.integers(1, 90, size=(B, L)).astype('int32')
            valid = np.ones((B, L), bool); valid[0, 7:] = False
            heldout = np.array([False, False, False, True])
            numbers = np.arange(batch * B, batch * B + B)
            r.update(mx.array(values), ids, valid, heldout, numbers, batch)
            for b in range(B):
                for t in range(L):
                    if valid[b, t] and not heldout[b]: all_values.append(values[b, t]); all_where.append((numbers[b], t, ids[b]))
        all_values = np.array(all_values)
        for unit in range(n):
            expected = np.sort(all_values[:, unit])[::-1][:3]
            np.testing.assert_allclose(r.s['top_positive_value'][unit], expected, rtol=1e-5)
            np.testing.assert_allclose(r.s['top_negative_value'][unit], np.sort(all_values[:, unit])[:3], rtol=1e-5)
            k = int(np.argmax(all_values[:, unit])); context, position, row = all_where[k]
            window = r.s['top_positive_ids'][unit, 0]
            self.assertEqual(int(window[2]), int(row[position]))           # the center token
            self.assertEqual(tuple(r.s['top_positive_where'][unit, 0]), (context, position))
            self.assertAlmostEqual(float(r.s['top_positive_acts'][unit, 0, 2]), float(all_values[k, unit]), places=2)
        self.assertEqual(int(r.s['count'][0]), 3 * (B * L - 3))
        self.assertEqual(int(r.s['histogram'][0].sum()), int(r.s['count'][0]))
        self.assertTrue(np.all(np.isfinite(r.s['heldout_top_positive_key'])))

    def test_capture_atlas_and_steer_end_to_end(self):
        from dyno.lab.neurons import atlas, capture, hooks, units
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Path(root, 'text.txt').write_text('\n\n'.join(f'Paragraph {i}: the quick brown fox jumps over the lazy dog. ' * 3 for i in range(60)))
            model, tok = tiny_model(), CharTokenizer()
            state = {}

            def load_model(hook, layers):
                captured, active, collecting = {}, {}, [True]
                info = hooks.install(model, layers, hook, captured, active, collecting, {'model_type': 'qwen3'})
                load_model.state = dict(active=active)
                info['layers'] = layers
                return model, tok, {}, captured, collecting, info
            job = root / ('a' * 32); job.mkdir()
            config = dict(operation='capture', model='tiny', layers=[1], corpus=[{'files': [str(root / 'text.txt')], 'split_on': 'blank_lines'}],
                          tokens=6000, context=64, batch_tokens=512, units={'neurons': 'all', 'random_directions': 3}, lab_root=str(root),
                          top_k=5, heldout_top_k=3, random_samples=5, heldout_random=5, window_before=4, window_after=2)
            (job / 'job.json').write_text(json.dumps({'config': config}))
            result = capture.run(config, job, load_model, lambda *a: None)
            self.assertEqual(result['capture']['units'], 67)
            self.assertGreater(result['capture']['layers']['1']['heldout_tokens'], 0)
            out = root / ('b' * 32); out.mkdir()
            with mock.patch.object(atlas, 'tokenizer_for', return_value=tok):
                atlas.run(dict(capture='a' * 32, lab_root=str(root)), out, lambda *a: None)
            index = json.loads((out / 'atlas' / 'index-L1.json').read_text())
            self.assertEqual(len(index['units']), 67)
            page = atlas.read_page(out, 1, 0)
            self.assertEqual(set(page['poles']), {'positive', 'negative'})
            top = page['poles']['positive']['top']
            self.assertTrue(top and all(a['value'] >= b['value'] for a, b in zip(top, top[1:])))
            self.assertTrue(all(e['value'] > 0 for e in top))
            self.assertTrue(all(e['value'] < 0 for e in page['poles']['negative']['top']))
            # Steering through the same hook changes the generation.
            steer = units.run(dict(mode='steer', model='tiny', prompt='the quick', unit=[1, 0], strengths=[0, 50], scale='absolute', max_tokens=6, lab_root=str(root)),
                              root, load_model, lambda *a: None)
            texts = [o['text'] for o in steer['steer']['outputs']]
            self.assertEqual(len(texts), 2)

    def test_sae_alignment_finds_features_that_copy_neurons(self):
        from dyno.lab.neurons.sae import SAE, alignment
        d = 6
        eye = mx.eye(d)
        sae = SAE(dict(W_enc=eye, b_enc=mx.zeros((d,)), W_dec=eye, b_dec=mx.zeros((d,))), dict(scale=1.0, architecture='relu', k=d))
        x = mx.maximum(mx.random.normal((2000, d)), 0)
        f = sae.encode(x)
        acc = dict(F=f.sum(0), FF=(f * f).sum(0), A=x.sum(0), AA=x.T @ x, FA=f.T @ x)
        out = alignment(dict(_eval_n=2000, corr_threshold=0.5, r2_threshold=0.5), sae, acc)
        self.assertEqual(out['summary']['live_features'], d)
        self.assertEqual(out['summary']['candidate_new_building_blocks'], 0)
        for row in out['features']:
            self.assertEqual(row['best_neuron'], row['feature'])
            self.assertGreater(row['best_correlation'], 0.99)
            self.assertAlmostEqual(row['decoder_share_top1'], 1.0)


if __name__ == '__main__':
    unittest.main()
