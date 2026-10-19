"""4-bit matmuls for 5-16 rows on the M5 GPU's neural accelerators.

Verifying drafted tokens multiplies every weight matrix by a handful of rows. MLX's kernels for
2-12 rows cost roughly in proportion to the rows, and from 13 rows it stages dequantized weights
through threadgroup memory; on Qwen3.8-27B (M5 Max) a 16-token verify takes 153 ms against 33 ms
for one token. This kernel reads each weight once, dequantizes it straight into the registers
of a NAX matmul (matmul2d, 16 x 32 x 16 per simdgroup) and costs about the same for 5 rows as for
16: the same 16-token verify takes 44 ms. Below 5 rows MLX's own kernels are faster and are kept.

C = X · Wᵀ: A is a 16 x 16 tile of x (rows padded to 16); B is two 16 x 16 tiles of w taken
transposed, so each lane's B elements are 4 consecutive k of one weight row. Lanes own
contiguous 64-wide k slices of their rows, and the k order inside a 256-wide block is permuted
the same way for x and w, so no data moves between lanes. Weights for the next block are loaded
while the current one is multiplied, and K is split across simdgroups so that narrow matrices
still keep every core streaming.

Only 4-bit, group-size-64 weights with bf16/fp16 activations are handled; everything else, and
any Mac without neural accelerators, uses MLX's kernels (`install` checks the kernel against
MLX once before enabling it).
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

import mlx.core as mx
import mlx.nn as nn

MIN_ROWS, MAX_ROWS = 5, 16
_KL = 64  # k per lane slice; a block is 4 * _KL wide

_HEADER = """
#include <metal_simdgroup>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
"""

_SOURCE = """
    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
        16, 32, 16, false, true, true, mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
    mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup> op;

    const uint lane = thread_index_in_simdgroup;
    const uint sg = simdgroup_index_in_threadgroup;
    const uint qid = lane >> 2;
    const uint fm = (qid & 4) | ((lane >> 1) & 3);   // fragment row of this lane (and fm + 8)
    const uint fn = ((qid & 2) | (lane & 1)) * 4;    // first of its 4 fragment columns
    const uint j = fn / 4;                           // which k slice of a block the lane owns
    const uint KW = K / 8;
    const uint KG = K / 64;
    constexpr uint WL = KL / 8;                      // packed words per slice and row
    constexpr uint BLK = 4 * KL;
    const uint n0 = threadgroup_position_in_grid.x * 32;

    // C tile q covers rows n0 + 16q .. +16: element 8q + 4h + e is (m = fm + 8h, n = n0 + 16q + fn + e).
    float acc[16];
    for (uint i = 0; i < 16; ++i) acc[i] = 0.0f;

    // B tile q, half h: weight row n0 + 16q + fm + 8h.
    uint wv[2][2][WL];
    float sc[2][2], bi[2][2];
    auto load = [&](uint kb, thread uint (&w)[2][2][WL], thread float (&s_)[2][2], thread float (&b_)[2][2]) {
        for (uint q = 0; q < 2; ++q)
            for (uint h = 0; h < 2; ++h) {
                const uint n = n0 + 16 * q + fm + 8 * h;
                const device uint* src = w_q + n * KW + (kb + KL * j) / 8;
                for (uint i = 0; i < WL; ++i) w[q][h][i] = src[i];
                const uint g = n * KG + (kb + KL * j) / 64;
                s_[q][h] = float(scales[g]);
                b_[q][h] = float(biases[g]);
            }
    };

    // Simdgroup sg of the threadgroup takes blocks sg, sg + SK, sg + 2 SK, ...
    const uint kbeg = sg * BLK;
    if (kbeg < K) load(kbeg, wv, sc, bi);
    for (uint kb = kbeg; kb < K; kb += SK * BLK) {
        uint wn[2][2][WL];
        float scn[2][2], bin[2][2];
        if (kb + SK * BLK < K) load(kb + SK * BLK, wn, scn, bin);
        for (uint s = 0; s < KL / 4; ++s) {
            const uint k = kb + KL * j + 4 * s;
            auto ct_a = op.template get_left_input_cooperative_tensor<T, T, float>();
            for (uint h = 0; h < 2; ++h) {
                const uint m = fm + 8 * h;
                for (uint e = 0; e < 4; ++e) ct_a[4 * h + e] = m < M ? x[m * K + k + e] : T(0);
            }
            auto ct_b = op.template get_right_input_cooperative_tensor<T, T, float>();
            const uint shift = 16 * (s % 2);
            for (uint q = 0; q < 2; ++q)
                for (uint h = 0; h < 2; ++h) {
                    const uint word = wv[q][h][s / 2] >> shift;
                    for (uint e = 0; e < 4; ++e)
                        ct_b[8 * q + 4 * h + e] = T(fma(sc[q][h], float((word >> (4 * e)) & 0xF), bi[q][h]));
                }
            auto ct_c = op.template get_destination_cooperative_tensor<decltype(ct_a), decltype(ct_b), float>();
            for (uint i = 0; i < 16; ++i) ct_c[i] = acc[i];
            op.run(ct_a, ct_b, ct_c);
            for (uint i = 0; i < 16; ++i) acc[i] = ct_c[i];
        }
        for (uint q = 0; q < 2; ++q)
            for (uint h = 0; h < 2; ++h) {
                for (uint i = 0; i < WL; ++i) wv[q][h][i] = wn[q][h][i];
                sc[q][h] = scn[q][h];
                bi[q][h] = bin[q][h];
            }
    }

    if (SK > 1) {
        threadgroup float red[SK * 16 * 32];
        for (uint i = 0; i < 16; ++i) red[(sg * 16 + i) * 32 + lane] = acc[i];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (sg != 0) return;
        for (uint o = 1; o < SK; ++o)
            for (uint i = 0; i < 16; ++i) acc[i] += red[(o * 16 + i) * 32 + lane];
    }

    for (uint q = 0; q < 2; ++q)
        for (uint h = 0; h < 2; ++h) {
            const uint m = fm + 8 * h;
            if (m >= M) continue;
            for (uint e = 0; e < 4; ++e) y[m * N + n0 + 16 * q + fn + e] = static_cast<T>(acc[8 * q + 4 * h + e]);
        }
"""

_kernel = None


def _get_kernel():
    global _kernel
    if _kernel is None:
        _kernel = mx.fast.metal_kernel(
            name="dyno_qmm_nax_4bit_g64",
            input_names=["x", "w_q", "scales", "biases"],
            output_names=["y"],
            source=_SOURCE,
            header=_HEADER,
        )
    return _kernel


def _split_k(N: int, K: int) -> int:
    """Simdgroups per threadgroup sharing K: enough to keep 40 cores streaming on narrow matrices."""
    return max(1, min(8, K // (4 * _KL), -(-1280 // (N // 32))))


def supports(layer: Any, x: mx.array) -> bool:
    rows = x.size // x.shape[-1]
    return (
        MIN_ROWS <= rows <= MAX_ROWS
        and getattr(layer, "mode", "affine") == "affine"
        and layer.bits == 4
        and layer.group_size == 64
        and x.dtype in (mx.bfloat16, mx.float16)
        and layer.weight.shape[0] % 32 == 0
        and x.shape[-1] % (4 * _KL) == 0
    )


def qmm(x: mx.array, w_q: mx.array, scales: mx.array, biases: mx.array) -> mx.array:
    """x @ dequantize(w).T for 4-bit, group-64 weights and at most 16 rows of x."""
    K = x.shape[-1]
    x2 = x.reshape(-1, K)
    M, N = x2.shape[0], w_q.shape[0]
    sk = _split_k(N, K)
    (y,) = _get_kernel()(
        inputs=[x2, w_q, scales, biases],
        template=[("T", x.dtype), ("M", M), ("SK", sk), ("KL", _KL), ("N", N), ("K", K)],
        grid=(N // 32 * 32 * sk, 1, 1),
        threadgroup=(32 * sk, 1, 1),
        output_shapes=[(M, N)],
        output_dtypes=[x.dtype],
    )
    return y.reshape(*x.shape[:-1], N)


_original_call: Optional[Any] = None


def _quantized_linear_call(self: nn.QuantizedLinear, x: mx.array) -> mx.array:
    if not supports(self, x):
        return _original_call(self, x)
    y = qmm(x, self["weight"], self["scales"], self["biases"])
    if "bias" in self:
        y = y + self["bias"]
    return y


def available() -> bool:
    """Whether this GPU runs the kernel and it agrees with MLX's own quantized matmul."""
    try:
        if not mx.metal.is_available() or not mx.device_info().get("architecture", "").startswith("applegpu_g17"):
            return False
        key = mx.random.key(0)
        w = (mx.random.normal((64, 512), key=key) * 0.02).astype(mx.bfloat16)
        w_q, scales, biases = mx.quantize(w, group_size=64, bits=4)
        x = mx.random.normal((7, 512), key=mx.random.key(1)).astype(mx.bfloat16)
        ref = mx.quantized_matmul(x, w_q, scales, biases, transpose=True, group_size=64, bits=4)
        out = qmm(x, w_q, scales, biases)
        err = mx.abs(out.astype(mx.float32) - ref.astype(mx.float32)).max() / mx.abs(ref.astype(mx.float32)).max()
        return bool(err.item() < 2e-2)
    except Exception as error:  # noqa: BLE001 - an older GPU or OS must keep MLX's kernels
        logging.info("NAX matmul unavailable: %s", error)
        return False


def install() -> bool:
    """Route 5-16-row 4-bit matmuls through the NAX kernel when it works on this Mac."""
    global _original_call
    if _original_call is not None:
        return True
    if os.environ.get("DYNO_NAX") == "0" or not available():
        return False
    _original_call = nn.QuantizedLinear.__call__
    nn.QuantizedLinear.__call__ = _quantized_linear_call
    return True
