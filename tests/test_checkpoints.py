"""Prompt-cache checkpoints on a real (tiny) hybrid model: same logits, and the next turn starts from the checkpoint."""
import unittest
from unittest import mock

try:
    import mlx.core as mx
    from mlx_lm.models.cache import LRUPromptCache, make_prompt_cache
    from mlx_lm.models.qwen3_5 import TextModel, TextModelArgs
    from dyno.serve import checkpoints
except ImportError:
    mx = None

START = 9  # stands in for <|im_start|>


class Tokenizer:
    def encode(self, text, add_special_tokens=False): return [START] if text == '<|im_start|>' else [1, 2]


class MarkTests(unittest.TestCase):
    def test_after_the_system_prompt_and_at_the_last_turn(self):
        from dyno.serve.checkpoints import marks
        tokens = [9, 1, 1, 9, 2, 2, 9, 3, 9, 4]
        self.assertEqual(marks(tokens, 9), [3, 8])
        self.assertEqual(marks([9, 1, 9, 2], 9), [2])
        self.assertEqual(marks([9, 1, 1], 9), [])
        self.assertEqual(marks(tokens, None), [])


@unittest.skipIf(mx is None, 'MLX runtime required')
class HybridCheckpointTests(unittest.TestCase):
    def setUp(self):
        mx.random.seed(3)
        self.model = TextModel(TextModelArgs(hidden_size=64, intermediate_size=128, num_hidden_layers=4, num_attention_heads=4,
                                             num_key_value_heads=2, vocab_size=128, head_dim=16, linear_num_value_heads=4,
                                             linear_num_key_heads=2, linear_key_head_dim=16, linear_value_head_dim=16,
                                             full_attention_interval=4))
        # system turn, a user turn, an assistant turn, a tool turn, then the reply header
        self.full = [START] + list(range(20, 60)) + [START] + list(range(60, 90)) + [START] + list(range(30, 50)) + [START] + [5, 6, 7]

    def same(self, a, b):
        # Prefill reads a stretch's last token on its own (the recurrent kernel, not the chunked one), as any prompt-cache
        # hit does: ~0.1% apart in float32, same next token.
        return mx.allclose(a, b, atol=5e-3).item() and mx.argmax(a).item() == mx.argmax(b).item()

    def logits(self, cache, tokens):
        out = self.model(mx.array([tokens]), cache=cache)[:, -1]
        mx.eval(out)
        return out

    def test_same_logits_and_the_next_turn_starts_at_the_last_checkpoint(self):
        store = LRUPromptCache(max_size=10)
        cache = make_prompt_cache(self.model)
        with mock.patch.object(checkpoints, 'MIN_SEGMENT', 4):
            rest = checkpoints._checkpoint((store, 'm', self.full), self.model, Tokenizer(), self.full, cache, None, 16)
        marks = checkpoints.marks(self.full, START)
        self.assertEqual(rest, self.full[marks[-1]:])
        with_checkpoints = self.logits(cache, rest)
        plain = self.logits(make_prompt_cache(self.model), self.full)
        self.assertTrue(self.same(with_checkpoints, plain))

        # The next turn re-renders the reply differently; it still starts with everything before the reply's header.
        following = self.full[:marks[-1]] + [START, 99, 98, 97, START, 11, 12]
        restored, left = store.fetch_nearest_cache('m', following)
        self.assertIsNotNone(restored)
        self.assertEqual(left, following[marks[-1]:])
        self.assertTrue(self.same(self.logits(restored, left), self.logits(make_prompt_cache(self.model), following)))

        # A new conversation with the same system prompt starts after it.
        other = self.full[:marks[0]] + [START, 1, 2, 3]
        _, left = store.fetch_nearest_cache('m', other)
        self.assertEqual(left, other[marks[0]:])

    def test_short_stretches_are_not_worth_a_checkpoint(self):
        store = LRUPromptCache(max_size=10)
        rest = checkpoints._checkpoint((store, 'm', self.full), self.model, Tokenizer(), self.full, make_prompt_cache(self.model), None, 16)
        self.assertEqual(rest, self.full)  # under MIN_SEGMENT tokens: read in one go
        self.assertEqual(len(store), 0)

    def test_a_prompt_the_lookup_did_not_see_is_left_alone(self):
        store = LRUPromptCache(max_size=10)
        with mock.patch.object(checkpoints, 'MIN_SEGMENT', 4):
            rest = checkpoints._checkpoint((store, 'm', [1, 2, 3]), self.model, Tokenizer(), self.full, make_prompt_cache(self.model), None, 16)
        self.assertEqual(rest, self.full)
        self.assertEqual(len(store), 0)


if __name__ == '__main__':
    unittest.main()
