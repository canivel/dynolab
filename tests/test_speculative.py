import json
import tempfile
import unittest
from pathlib import Path

try:
    from dyno.serve import mtp, speculative
    from dyno.serve.cli import _explicit_concurrency, _single_stream_at_concurrency_one, _take_speculative_flags
    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False
needs_mlx_lm = unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")


@needs_mlx_lm
class SpeculativeFlags(unittest.TestCase):
    def test_dyno_flags_are_stripped_before_mlx_lm_sees_them(self):
        argv, options = _take_speculative_flags(
            ["--model", "m", "--speculative", "off", "--mtp-head=/tmp/head", "--port", "1"]
        )
        self.assertEqual(argv, ["--model", "m", "--port", "1"])
        self.assertEqual(options, {"mode": "off", "head": "/tmp/head", "dflash": None})

    def test_auto_is_the_default(self):
        self.assertEqual(_take_speculative_flags(["--model", "m"])[1]["mode"], "auto")

    def test_rejects_unknown_mode(self):
        with self.assertRaises(SystemExit):
            _take_speculative_flags(["--speculative", "fast"])

    def test_reads_explicit_concurrency(self):
        self.assertEqual(_explicit_concurrency(["--decode-concurrency", "4"]), 4)
        self.assertEqual(_explicit_concurrency(["--decode-concurrency=1"]), 1)
        self.assertIsNone(_explicit_concurrency(["--model", "m"]))

    def test_one_request_at_a_time_skips_the_batch_generator(self):
        def server():
            class ModelProvider:
                def load(self, model_path, adapter_path=None, draft_model_path=None):
                    self.is_batchable = True  # what mlx_lm decides for a model without a drafter
            return type("Module", (), {"ModelProvider": ModelProvider})

        for argv, batchable in ((["--decode-concurrency", "1"], False), (["--decode-concurrency", "4"], True), ([], True)):
            module = server()
            _single_stream_at_concurrency_one(module, argv)
            provider = module.ModelProvider()
            provider.load("m")
            self.assertEqual(provider.is_batchable, batchable, argv)


@needs_mlx_lm
class HeadResolution(unittest.TestCase):
    def test_base_name_ignores_quantisation_and_publisher(self):
        self.assertEqual(mtp.base_name("lmstudio-community/Qwen3.8-27B-MLX-4bit"), "Qwen3.8-27B")
        self.assertEqual(mtp.base_name("/x/models--Qwen--Qwen3.6-35B-A3B/snapshots/1"), "Qwen3.6-35B-A3B")
        self.assertIsNone(mtp.base_name("mlx-community/Llama-3-8B"))

    def test_models_without_a_head_get_no_drafter(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "config.json").write_text(json.dumps({"text_config": {"mtp_num_hidden_layers": 0}}))
            self.assertFalse(mtp.ships_mtp_head(tmp))
            self.assertIsNone(mtp.resolve_head("Qwen3.8-27B", tmp))

    def test_mixture_of_experts_heads_are_not_fetched(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = {"text_config": {"mtp_num_hidden_layers": 1, "num_experts": 256}}
            Path(tmp, "config.json").write_text(json.dumps(config))
            self.assertIsNone(mtp.resolve_head("Qwen3.6-35B-A3B", tmp, download=True))

    def test_reads_only_the_requested_tensors(self):
        import mlx.core as mx

        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp, "shard.safetensors"))
            tensors = {
                "model.w": mx.arange(6, dtype=mx.float32).reshape(2, 3),
                "mtp.fc.weight": (mx.arange(8, dtype=mx.float32) / 3).astype(mx.bfloat16).reshape(4, 2),
                "mtp.norm.weight": mx.array([0.5, -1.25], dtype=mx.float16),
            }
            mx.save_safetensors(path, tensors)
            with open(path, "rb") as handle:
                read = mtp.read_safetensors(handle, ["mtp.norm.weight", "mtp.fc.weight"])
        self.assertEqual(set(read), {"mtp.fc.weight", "mtp.norm.weight"})
        for key, value in read.items():
            self.assertEqual(value.dtype, tensors[key].dtype)
            self.assertTrue(mx.array_equal(value, tensors[key]).item())


@needs_mlx_lm
class DraftLength(unittest.TestCase):
    def test_drafts_deeper_when_drafts_keep_surviving(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(4, 4, 0.06)
        self.assertGreaterEqual(policy.choose(4), 3)

    def test_recovers_after_a_run_of_rejections(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(1, 0, 0.04)
        policy = policy.fresh()
        for _ in range(400):
            k = policy.choose(4)
            policy.update(k, k, 0.04 + 0.005 * k)
        self.assertGreaterEqual(policy.choose(4), 3)

    def test_stops_drafting_when_drafts_are_rejected(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(3, 0, 0.06)
        self.assertEqual(policy.choose(4), 0)

    @staticmethod
    def _run(plain, per_draft, accept=0.62, rounds=600, k_max=7):
        """Simulated decoding: plain step seconds, extra seconds per drafted token; returns tokens/s and choices."""
        import random
        rng, policy, tokens, seconds, picks = random.Random(0), speculative.DraftPolicy(), 0, 0.0, []
        for _ in range(rounds):
            k = policy.choose(k_max)
            j = 0
            while j < k and rng.random() < accept: j += 1
            took = plain + per_draft * k
            policy.update(k, j, took)
            tokens, seconds = tokens + j + 1, seconds + took
            picks.append(k)
        return tokens / seconds, picks

    def test_a_gpu_where_verifying_is_expensive_decodes_plain(self):
        # M4 Max-like, no NAX (drafts up to 3): each drafted token adds 80% of a plain step, so any
        # drafting is slower than plain at 62% acceptance. The old policy always drafted (>= 1).
        rate, picks = self._run(plain=1 / 18.5, per_draft=0.8 / 18.5, k_max=3)
        self.assertGreater(picks[-200:].count(0), 160)  # one probe in 8 rounds drafts
        self.assertGreater(rate, 0.95 * 18.5)

    def test_a_gpu_where_verifying_is_cheap_keeps_drafting(self):
        # M5 Max-like with NAX: each drafted token adds 15% of a plain step; best possible is ~1.55x plain.
        rate, picks = self._run(plain=1 / 20.0, per_draft=0.15 / 20.0)
        self.assertLess(picks[-200:].count(0), 10)
        self.assertGreater(rate, 1.4 * 20.0)


if __name__ == "__main__":
    unittest.main()
