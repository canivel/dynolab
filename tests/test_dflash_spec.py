import unittest

try:
    import mlx.core as mx

    from dyno.serve import dflash_spec
    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False


@unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")
class DrafterState(unittest.TestCase):
    def test_state_tracks_positions_and_tokens(self):
        state = dflash_spec.DFlashState(2)
        state.add(mx.zeros((1, 4, 8)))
        state.add(mx.zeros((1, 3, 8)))
        state.drop(2)
        self.assertEqual(state.position, 5)
        self.assertEqual(state.pending.shape[1], 5)


if __name__ == "__main__":
    unittest.main()
