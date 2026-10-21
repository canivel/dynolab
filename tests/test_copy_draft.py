import random
import unittest

from dyno.serve import copy_draft
from dyno.serve.copy_draft import CopyDrafter, NgramIndex, VerifyCost

try:
    from dyno.serve import speculative
    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False
needs_mlx_lm = unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")

FILE = list(range(100, 160))  # a "file" of 60 distinct tokens


def rewrite(drafter, target, baseline=2.0):  # MTP's rate on code with the M5 kernel
    """Feed `target` through the drafter as a loop would: returns (rounds, copied tokens kept)."""
    produced, rounds, kept = 1, 0, 0
    drafter.observe(target[:1])
    while produced < len(target):
        draft = drafter.propose(baseline, None, len(target) - produced)
        rounds += 1
        if draft is None:
            out = target[produced : produced + 1]
        else:
            j = 0
            while j < len(draft.tokens) and produced + j < len(target) and draft.tokens[j] == target[produced + j]:
                j += 1
            drafter.feedback(draft, j, 0.05)
            kept += j
            out = target[produced : produced + j + 1]
        drafter.observe(out)
        produced += len(out)
    return rounds, kept


class Index(unittest.TestCase):
    def test_finds_where_the_newest_tokens_appeared_before(self):
        idx = NgramIndex(2)
        idx.append([1, 2, 3, 4, 9, 1, 2])
        self.assertEqual(idx.candidates((1, 2), len(idx)), [2])
        self.assertEqual(idx.agree(2, 10), 2)


class Copying(unittest.TestCase):
    def test_a_file_returned_with_one_edit_is_mostly_copied(self):
        target = FILE[:30] + [999] + FILE[31:]
        rounds, kept = rewrite(CopyDrafter([7, 8] + FILE + [9], VerifyCost(nax=True)), target)
        self.assertGreater(kept, 40)
        self.assertLess(rounds, 20)

    def test_fresh_text_is_left_to_the_model_drafter(self):
        rng = random.Random(0)
        drafter = CopyDrafter([rng.randrange(1000, 50000) for _ in range(500)])
        drafter.observe([rng.randrange(1000, 50000) for _ in range(50)])
        self.assertIsNone(drafter.propose(2.0, None, 100))

    def test_a_copy_must_beat_the_model_drafter(self):
        drafter = CopyDrafter(FILE, VerifyCost(nax=True))
        drafter.observe(FILE[:10])
        self.assertIsNotNone(drafter.propose(2.0, None, 100))
        self.assertIsNone(drafter.propose(10.0, None, 100))

    def test_copies_stop_at_the_budget(self):
        drafter = CopyDrafter(FILE)
        drafter.observe(FILE[:3])
        self.assertLessEqual(len(drafter.propose(1.0, None, 2).tokens), 2)

    def test_resumes_after_an_edit(self):
        drafter = CopyDrafter(FILE)
        drafter.observe(FILE[:10])
        draft = drafter.propose(1.0, None, 100)
        drafter.feedback(draft, 5, 0.05)
        drafter.observe(FILE[10:15] + [999])  # the model wrote its own token instead of FILE[15]
        drafter.observe([FILE[16]])
        self.assertEqual(drafter.propose(1.0, None, 100).tokens[0], FILE[17])

    def test_prefers_the_copy_it_was_following(self):
        line = [5, 6, 7, 8]
        prompt = line + [1, 2] + line + [3, 4] + list(range(200, 220))
        drafter = CopyDrafter(prompt)
        drafter.pointer = 4  # mid-way through the first copy of the line
        drafter.observe(line)
        self.assertEqual(drafter.propose(1.0, None, 100).tokens[0], 1)

    def test_learns_that_copies_keep_failing(self):
        drafter = CopyDrafter(FILE)
        drafter.observe(FILE[:8])
        for _ in range(60):
            draft = drafter.propose(1.0, None, 100)
            if draft is None:
                break
            drafter.feedback(draft, 0, 0.05)
        self.assertIsNone(drafter.propose(1.5, None, 100))


class Cost(unittest.TestCase):
    def test_measured_rounds_replace_the_prior(self):
        cost = VerifyCost(nax=True)
        self.assertAlmostEqual(cost(8, None), 1.48)
        cost.update(8, 0.06)
        self.assertAlmostEqual(cost(8, 0.03), 2.0)

    def test_without_the_kernel_wide_verifies_cost_more(self):
        self.assertGreater(VerifyCost(nax=False)(8, None), 2 * VerifyCost(nax=True)(8, None))


class Context(unittest.TestCase):
    def tearDown(self):
        copy_draft.request_prompt = None

    def test_uses_the_whole_prompt_when_the_cache_covered_its_start(self):
        copy_draft.request_prompt = [1, 2, 3, 4, 5]
        self.assertEqual(copy_draft.context([4, 5]), [1, 2, 3, 4, 5])

    def test_ignores_a_prompt_from_another_request(self):
        copy_draft.request_prompt = [1, 2, 3, 4, 5]
        self.assertEqual(copy_draft.context([6, 7]), [6, 7])


@needs_mlx_lm
class Acceptance(unittest.TestCase):
    def test_a_copied_token_keeps_the_target_distribution(self):
        """Accept with p(d), else sample p without d: the token's law is exactly p."""
        import mlx.core as mx

        p = mx.array([[0.5, 0.3, 0.15, 0.05]])
        d = mx.array([1])
        q = speculative.one_hot(d, p)
        n = 20000
        accept = mx.random.uniform(shape=(n,)) < p[0, 1] / q[0, 1]
        residual = mx.maximum(p - q, 0.0)
        residual = residual / residual.sum(-1, keepdims=True)
        resampled = mx.random.categorical(mx.log(mx.broadcast_to(residual, (n, 4))))
        token = mx.where(accept, d, resampled)
        freq = [(token == i).sum().item() / n for i in range(4)]
        for got, want in zip(freq, p[0].tolist()):
            self.assertAlmostEqual(got, want, delta=0.015)


@needs_mlx_lm
class Baseline(unittest.TestCase):
    def test_rate_is_tokens_per_plain_step(self):
        policy = speculative.DraftPolicy()
        for _ in range(100):
            policy.update(0, 0, 0.03)
            policy.update(3, 3, 0.045)  # 4 tokens in 1.5 plain steps
        self.assertAlmostEqual(policy.rate(3), 4 / 1.5, delta=0.05)


if __name__ == "__main__":
    unittest.main()
