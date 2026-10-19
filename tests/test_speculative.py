import json
import tempfile
import unittest
from pathlib import Path

try:
    from dyno.serve import mtp, speculative
    from dyno.serve.cli import _explicit_concurrency, _take_speculative_flags
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

    def test_backs_off_when_drafts_are_rejected(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(3, 0, 0.06)
        self.assertEqual(policy.choose(4), 1)


if __name__ == "__main__":
    unittest.main()
