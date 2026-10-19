import unittest

try:
    import mlx.core as mx
    import mlx.nn as nn

    from dyno.serve import nax_matmul
    HAS_NAX = nax_matmul.available()
except ImportError:
    HAS_NAX = False


@unittest.skipUnless(HAS_NAX, "needs a GPU with neural accelerators (M5 or later)")
class NAXMatmul(unittest.TestCase):
    def test_matches_mlx_for_every_row_count_and_width(self):
        w = (mx.random.normal((96, 1024), key=mx.random.key(0)) * 0.02).astype(mx.bfloat16)
        for bits in (4, 8):
            w_q, scales, biases = mx.quantize(w, group_size=64, bits=bits)
            for rows in range(nax_matmul.MIN_ROWS, nax_matmul.MAX_ROWS + 1):
                x = mx.random.normal((1, rows, 1024), key=mx.random.key(rows)).astype(mx.bfloat16)
                ref = mx.quantized_matmul(x, w_q, scales, biases, transpose=True, group_size=64, bits=bits)
                out = nax_matmul.qmm(x, w_q, scales, biases)
                self.assertEqual(out.shape, ref.shape)
                err = (mx.abs(out - ref).max() / mx.abs(ref).max()).item()
                self.assertLess(err, 2e-2, f"{bits} bits, {rows} rows")

    def test_only_takes_the_shapes_it_handles(self):
        four = nn.QuantizedLinear.from_linear(nn.Linear(1024, 64, bias=False), group_size=64, bits=4)
        three = nn.QuantizedLinear.from_linear(nn.Linear(1024, 64, bias=False), group_size=64, bits=3)
        x = lambda rows: mx.zeros((1, rows, 1024), dtype=mx.bfloat16)
        self.assertTrue(nax_matmul.supports(four, x(5)))
        self.assertTrue(nax_matmul.supports(four, x(16)))
        self.assertFalse(nax_matmul.supports(four, x(4)))  # MLX's own kernel is faster
        self.assertFalse(nax_matmul.supports(four, x(17)))
        self.assertFalse(nax_matmul.supports(three, x(8)))
        self.assertFalse(nax_matmul.supports(four, x(8).astype(mx.float32)))


if __name__ == "__main__":
    unittest.main()
