import threading
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from dyno.serve.activations import CaptureBroker, capture, validate
try:
    import mlx.core as mx
    from mlx_lm.models.qwen3_5 import TextModel, TextModelArgs
except ImportError:
    mx = None


class CaptureQueueTests(unittest.TestCase):
    def test_rejects_interventions_and_unbounded_inputs(self):
        good = dict(model='resident', prompt='hello', layers=[0])
        for extra in [dict(intervention='scale'), dict(layers=[0,0]), dict(max_input_tokens=257)]:
            with self.assertRaises(ValueError): validate(dict(good, **extra))

    def test_timeout_cancels_pending_capture(self):
        broker = CaptureBroker()
        with self.assertRaises(TimeoutError):
            broker.submit(dict(model='m',prompt='hello'), timeout=.001)
        with patch('dyno.serve.activations.capture') as run:
            broker.service(None)
            run.assert_not_called()
        self.assertFalse(broker.slot.locked())

    def test_capture_only_executes_on_scheduler_caller(self):
        broker = CaptureBroker(); result = []
        thread = threading.Thread(target=lambda: result.append(broker.submit(dict(model='m',prompt='hello'))))
        thread.start()
        # Wait for enqueue without sleeps or a model forward on the submitting thread.
        with broker.queue.not_empty:
            broker.queue.not_empty.wait_for(lambda: len(broker.queue.queue) > 0, timeout=1)
        calls = []
        with patch('dyno.serve.activations.capture', side_effect=lambda *args: calls.append(threading.get_ident()) or {'ok':True}):
            broker.service(None)
        thread.join(1)
        self.assertEqual(calls, [threading.get_ident()])
        self.assertEqual(result, [{'ok':True}])


@unittest.skipIf(mx is None, 'MLX runtime required')
class ResidentCaptureTests(unittest.TestCase):
    def test_no_reload_same_logits_and_restoration_on_error(self):
        model = TextModel(TextModelArgs(hidden_size=64, intermediate_size=128,
            num_hidden_layers=4, num_attention_heads=4, num_key_value_heads=2,
            vocab_size=128, head_dim=16, linear_num_value_heads=4, linear_num_key_heads=2,
            linear_key_head_dim=16, linear_value_head_dim=16, full_attention_interval=4))
        tokenizer = SimpleNamespace(encode=lambda _: [1,2,3], decode=lambda ids: str(ids))
        provider = SimpleNamespace(model_key=('resident',None,None), model=model, tokenizer=tokenizer)
        original = list(model.layers)
        ids = mx.array([[1,2,3]])
        baseline = model(ids); mx.eval(baseline)
        result = capture(provider, dict(model='resident',prompt='hello',layers=[0,3]))
        self.assertEqual(len(result['layers'][0]['norms']),3)
        self.assertTrue(all(a is b for a,b in zip(original,model.layers)))
        self.assertTrue(bool(mx.allclose(baseline, model(ids))))
        with self.assertRaises(ValueError): capture(provider,dict(model='different',prompt='hello'))
        # An error after wrappers were installed must also restore every original.
        with patch.object(TextModel, '__call__', side_effect=ValueError('forward failure')):
            with self.assertRaises(ValueError): capture(provider,dict(model='resident',prompt='hello'))
        self.assertTrue(all(a is b for a,b in zip(original,model.layers)))
