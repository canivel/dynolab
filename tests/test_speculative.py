import json
import tempfile
import unittest
from pathlib import Path

from dyno.serve.cli import _explicit_concurrency, _take_speculative_flags

try:
    from dyno.serve import mtp, speculative
    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False
needs_mlx_lm = unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")


class SpeculativeFlags(unittest.TestCase):
    def test_dyno_flags_are_stripped_before_mlx_lm_sees_them(self):
        argv, options = _take_speculative_flags(
            ["--model", "m", "--speculative", "off", "--mtp-head=/tmp/head", "--port", "1"]
        )
        self.assertEqual(argv, ["--model", "m", "--port", "1"])
        self.assertEqual(options, {"mode": "off", "head": "/tmp/head"})

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


@needs_mlx_lm
class DraftLength(unittest.TestCase):
    def test_drafts_deeper_when_drafts_keep_surviving(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(4, 4, 0.06)
        self.assertGreaterEqual(policy.choose(4), 3)

    def test_backs_off_when_drafts_are_rejected(self):
        policy = speculative.DraftPolicy()
        for _ in range(200):
            policy.update(3, 0, 0.06)
        self.assertEqual(policy.choose(4), 1)


if __name__ == "__main__":
    unittest.main()
