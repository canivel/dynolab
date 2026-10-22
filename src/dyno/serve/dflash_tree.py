"""DFlash2 draft trees, verified in one target pass on Qwen3.5/3.6/3.8 (Gated-DeltaNet + attention).

A chain verifies one guess per position. DFlash2's selector scores the top 16 candidates of every
position and how well each follows each candidate before it; a tree keeps the 15 likeliest
prefixes of that lattice instead of one path. When the selector's first choice is wrong, a
second or third candidate is often right, and the round keeps going. On an M5 Max the tree
keeps 15-50% more tokens per round than a 15-token chain at the same verify width.

Rows of the verify are the anchor (row 0) then the nodes in depth-first order, best child first:

    attention   RoPE at offset + depth; each row sees the cache, its ancestors and itself
    GDN         the depthwise conv reads each row's ancestors; the recurrence starts each row
                from its parent's state (all 16 states fit in one thread's registers)
    commit      the accepted path's KV rows move together and the GDN layers replay the path
                from the old state (`speculative._replay`, as a chain rollback does)

Output stays exact. Greedy keeps a child while it is the target's argmax. Sampled tries the
children in order: accept c with p(c) over the mass left, else remove c; when none is
accepted, sample from what remains. Each emitted token then follows the target's p exactly.

The best-first tree over the selector lattice follows mlx-serve's `bestFirstTree`
(https://github.com/ddalcu/mlx-serve, MIT licence, dflash.zig).
"""

from __future__ import annotations

import heapq
import itertools
import math
import os
from typing import Any, List, Optional, Sequence, Tuple

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models import qwen3_5, qwen3_next
from mlx_lm.models.cache import KVCache
from mlx_lm.models.gated_delta import compute_g

from . import speculative as S

ENABLED = os.environ.get("DYNO_DFLASH_TREES", "1") != "0"
MAX_NODES = 15  # with the anchor: a 16-row verify, what the NAX kernel serves for the price of 5
CHILDREN, TAU, EDGE_WEIGHT = 4, 1.5, 0.6  # mlx-serve's TreeParams defaults

ACTIVE: Optional["Tree"] = None  # the tree whose rows the target is verifying


class Tree:
    """Nodes in depth-first order; `parents[i]` is a node index or -1 (under the anchor)."""

    def __init__(self, tokens: Sequence[int], parents: Sequence[int], depth: Sequence[int]):
        self.row_token: List[Optional[int]] = [None] + list(tokens)
        self.row_parent = [-1] + [p + 1 for p in parents]
        self.L = len(self.row_parent)
        ancestry, conv_rows = [], []
        for r in range(self.L):
            line, c = [False] * self.L, r
            while c >= 0:
                line[c] = True
                c = self.row_parent[c]
            ancestry.append(line)
            # The conv window of row r: its three nearest ancestors, then the cached conv rows.
            # Index into concat(conv_state (3 rows), verify rows).
            window, c = [], r
            while len(window) < 4 and c >= 0:
                window.append(3 + c)
                c = self.row_parent[c]
            window += [2, 1, 0][: 4 - len(window)]
            conv_rows.append(window[::-1])
        self.ancestry = mx.array(ancestry)
        self.conv_rows = mx.array(conv_rows, dtype=mx.int32)
        self.parents = mx.array(self.row_parent, dtype=mx.int32)
        self.depth = mx.array([0] + [d + 1 for d in depth], dtype=mx.int32)
        self.children = [[c for c in range(self.L) if self.row_parent[c] == r] for r in range(self.L)]

    @property
    def tokens(self) -> List[int]:
        return self.row_token[1:]

    def walk_greedy(self, choice: Sequence[int]) -> List[int]:
        """Rows of the accepted path while the target's argmax is a child of the last row."""
        path, cur = [0], 0
        while True:
            nxt = next((c for c in self.children[cur] if self.row_token[c] == choice[cur]), None)
            if nxt is None:
                return path
            path.append(nxt)
            cur = nxt

    def walk_sampled(self, child_p: dict, uniforms: Sequence[Sequence[float]]) -> Tuple[List[int], List[int]]:
        """Rows of the accepted path, and the tokens removed at its last row (the bonus row).

        child_p[(row, token)]: the target's probability of that child at that row.
        """
        path, cur = [0], 0
        while True:
            left, nxt, removed = 1.0, None, []
            for i, c in enumerate(self.children[cur]):
                p = child_p[(cur, self.row_token[c])]
                if uniforms[cur][i] * left < p:
                    nxt = c
                    break
                left -= p
                removed.append(self.row_token[c])
            if nxt is None:
                return path, removed
            path.append(nxt)
            cur = nxt


def lattice(selector: Any, draft_hidden: mx.array, logits: mx.array, anchor: mx.array):
    """DFlash2's candidate lattice as lists: cands/unary [m][k], e0 [k], e [m-1][k][k]."""
    k = selector.top_k
    cands = mx.argpartition(logits, -k, axis=-1)[..., -k:]
    unary = mx.take_along_axis(logits, cands, axis=-1).astype(mx.float32)[0]
    h = selector.hidden_projection(draft_hidden)[0]
    successors = selector.successor_codebook(cands)[0]
    predecessors = selector.predecessor_codebook(cands)[0]
    e0 = (selector.predecessor_codebook(anchor.reshape(-1))[0] * h[0] * successors[0]).sum(-1).astype(mx.float32)
    e = mx.einsum("mar,mr,mjr->maj", predecessors[:-1], h[1:], successors[1:]).astype(mx.float32)
    mx.eval(cands, unary, e0, e)
    return cands[0].tolist(), unary.tolist(), e0.tolist(), e.tolist()


def build(cands, unary, e0, e, max_nodes: int = MAX_NODES) -> Tree:
    """The max_nodes likeliest prefixes of the lattice, best first, in depth-first order."""
    m = len(unary)
    queue: list = []
    counter = itertools.count()
    nodes: List[Tuple[int, int, int]] = []  # (token, parent, depth)

    def push(parent: int, cand: Optional[int], depth: int, base: float) -> None:
        edge = e0 if cand is None else e[depth - 1][cand]
        scores = [(u + EDGE_WEIGHT * w) / TAU for u, w in zip(unary[depth], edge)]
        top = max(scores)
        lse = top + math.log(sum(math.exp(s - top) for s in scores))
        for j in sorted(range(len(scores)), key=lambda j: -scores[j])[:CHILDREN]:
            heapq.heappush(queue, (-(base + scores[j] - lse), next(counter), parent, depth, j))

    push(-1, None, 0, 0.0)
    while len(nodes) < max_nodes and queue:
        neg, _, parent, depth, j = heapq.heappop(queue)
        nodes.append((int(cands[depth][j]), parent, depth))
        if depth + 1 < m:
            push(len(nodes) - 1, j, depth + 1, -neg)

    kids: dict = {i: [] for i in range(-1, len(nodes))}
    for i, (_, parent, _) in enumerate(nodes):
        kids[parent].append(i)
    order, stack = [], list(reversed(kids[-1]))
    while stack:
        i = stack.pop()
        order.append(i)
        stack.extend(reversed(kids[i]))
    renumber = {old: new for new, old in enumerate(order)}
    return Tree([nodes[o][0] for o in order], [renumber.get(nodes[o][1], -1) for o in order],
                [nodes[o][2] for o in order])


# --- Target pass over a tree ---------------------------------------------------------

_TREE_RECURRENCE = """
    auto n = thread_position_in_grid.z;
    auto hv_idx = n % Hv;
    auto hk_idx = hv_idx / (Hv / Hk);
    constexpr int n_per_t = Dk / 32;
    auto q_ = q + hk_idx * Dk;
    auto k_ = k + hk_idx * Dk;
    auto v_ = v + hv_idx * Dv;
    auto y_ = y + hv_idx * Dv;
    auto dk_idx = thread_position_in_threadgroup.x;
    auto dv_idx = thread_position_in_grid.y;
    auto i_state = state_in + (n * Dv + dv_idx) * Dk;

    // Each row starts from its parent's state (the cache's for row 0); rows come after their parents.
    float root[n_per_t];
    for (int i = 0; i < n_per_t; ++i) root[i] = static_cast<float>(i_state[n_per_t * dk_idx + i]);
    float st[TMAX * n_per_t];
    for (int t = 0; t < T; ++t) {
      const int p = parents[t];
      const float decay = g[t * Hv + hv_idx];
      float s[n_per_t];
      if (p < 0) { for (int i = 0; i < n_per_t; ++i) s[i] = root[i] * decay; }
      else { for (int i = 0; i < n_per_t; ++i) s[i] = st[p * n_per_t + i] * decay; }
      float kv_mem = 0.0f;
      for (int i = 0; i < n_per_t; ++i) kv_mem += s[i] * static_cast<float>(k_[t * Hk * Dk + n_per_t * dk_idx + i]);
      kv_mem = simd_sum(kv_mem);
      const float delta = (static_cast<float>(v_[t * Hv * Dv + dv_idx]) - kv_mem) * static_cast<float>(beta[t * Hv + hv_idx]);
      float out = 0.0f;
      for (int i = 0; i < n_per_t; ++i) {
        const int s_idx = n_per_t * dk_idx + i;
        s[i] = s[i] + static_cast<float>(k_[t * Hk * Dk + s_idx]) * delta;
        out += s[i] * static_cast<float>(q_[t * Hk * Dk + s_idx]);
        st[t * n_per_t + i] = s[i];
      }
      out = simd_sum(out);
      if (thread_index_in_simdgroup == 0) y_[t * Hv * Dv + dv_idx] = static_cast<InT>(out);
    }
"""

_kernel = None


def gated_delta_tree(q, k, v, g, beta, state, parents) -> mx.array:
    """mlx_lm's gated-delta recurrence (batch 1) where row t continues from row parents[t]."""
    global _kernel
    if _kernel is None:
        _kernel = mx.fast.metal_kernel(
            name="dyno_gated_delta_tree",
            input_names=["q", "k", "v", "g", "beta", "state_in", "parents", "T"],
            output_names=["y"],
            source=_TREE_RECURRENCE,
        )
    _, T, Hk, Dk = k.shape
    Hv, Dv = v.shape[2:]
    (y,) = _kernel(
        inputs=[q, k, v, g, beta, state, parents, T],
        template=[("InT", q.dtype), ("Dk", Dk), ("Dv", Dv), ("Hk", Hk), ("Hv", Hv), ("TMAX", MAX_NODES + 1)],
        grid=(32, Dv, Hv), threadgroup=(32, 4, 1),
        output_shapes=[(1, T, Hv, Dv)], output_dtypes=[q.dtype],
    )
    return y


def _gdn_tree(self, inputs: mx.array, cache: Any) -> mx.array:
    """GatedDeltaNet over the tree's rows; the cache is left for `Commit` to advance."""
    tree = ACTIVE
    B, L, _ = inputs.shape
    qkv = self.in_proj_qkv(inputs)
    z = self.in_proj_z(inputs).reshape(B, L, self.num_v_heads, self.head_v_dim)
    b = self.in_proj_b(inputs)
    a = self.in_proj_a(inputs)
    if S._capture is not None:
        S._capture.append(S._GDNRecord(self, cache, cache[0], cache[1], qkv, a, b))
    conv_state = cache[0]
    if conv_state is None:
        conv_state = mx.zeros((B, self.conv_kernel_size - 1, self.conv_dim), dtype=inputs.dtype)
    window = mx.concatenate([conv_state, qkv], axis=1)[:, tree.conv_rows]  # (B, L, 4, C)
    conv_out = nn.silu((window * self.conv1d.weight[:, :, 0].T).sum(axis=2))
    q, k, v = [
        t.reshape(B, L, h, d)
        for t, h, d in zip(
            mx.split(conv_out, [self.key_dim, 2 * self.key_dim], -1),
            [self.num_k_heads, self.num_k_heads, self.num_v_heads],
            [self.head_k_dim, self.head_k_dim, self.head_v_dim],
        )
    ]
    inv_scale = k.shape[-1] ** -0.5
    q = (inv_scale**2) * mx.fast.rms_norm(q, None, 1e-6)
    k = inv_scale * mx.fast.rms_norm(k, None, 1e-6)
    state = cache[1]
    if state is None:
        state = mx.zeros((B, self.num_v_heads, self.head_v_dim, self.head_k_dim), dtype=mx.float32)
    y = gated_delta_tree(q, k, v, compute_g(self.A_log, a, self.dt_bias), mx.sigmoid(b), state, tree.parents)
    return self.out_proj(self.norm(y, z).reshape(B, L, -1))


def _attention_tree(self, x: mx.array, cache: Any) -> mx.array:
    """Qwen3-Next attention over the tree's rows: positions by depth, ancestry mask."""
    tree = ACTIVE
    B, L, _ = x.shape
    queries, gate = mx.split(self.q_proj(x).reshape(B, L, self.num_attention_heads, -1), 2, axis=-1)
    gate = gate.reshape(B, L, -1)
    keys, values = self.k_proj(x), self.v_proj(x)
    queries = self.q_norm(queries).transpose(0, 2, 1, 3)
    keys = self.k_norm(keys.reshape(B, L, self.num_key_value_heads, -1)).transpose(0, 2, 1, 3)
    values = values.reshape(B, L, self.num_key_value_heads, -1).transpose(0, 2, 1, 3)
    offset = cache.offset
    positions = offset + tree.depth
    # RoPE takes one offset per batch entry: put the rows on the batch axis.
    queries = self.rope(queries.transpose(2, 1, 0, 3), offset=positions).transpose(2, 1, 0, 3)
    keys = self.rope(keys.transpose(2, 1, 0, 3), offset=positions).transpose(2, 1, 0, 3)
    keys, values = cache.update_and_fetch(keys, values)
    mask = mx.concatenate([mx.ones((L, offset), dtype=mx.bool_), tree.ancestry], axis=1)
    out = mx.fast.scaled_dot_product_attention(queries, keys, values, scale=self.scale, mask=mask)
    return self.o_proj(out.transpose(0, 2, 1, 3).reshape(B, L, -1) * mx.sigmoid(gate))


def supported(target_cache: List[Any]) -> bool:
    """Plain KV caches next to GDN caches, one stream, layers from mlx_lm's qwen3_5 / qwen3_next."""
    return ENABLED and all(isinstance(c, KVCache) or type(c).__name__ == "ArraysCache" for c in target_cache)


def install() -> None:
    """Route a verify over `ACTIVE`'s rows through the tree versions of both layer kinds."""
    gdn, attention = qwen3_5.GatedDeltaNet.__call__, qwen3_next.Qwen3NextAttention.__call__
    if getattr(gdn, "_dyno_tree", False):
        return

    def gdn_call(self, inputs, mask=None, cache=None):
        if ACTIVE is not None and cache is not None and inputs.shape[1] == ACTIVE.L:
            return _gdn_tree(self, inputs, cache)
        return gdn(self, inputs, mask, cache)

    def attention_call(self, x, mask=None, cache=None):
        if ACTIVE is not None and cache is not None and x.shape[1] == ACTIVE.L:
            return _attention_tree(self, x, cache)
        return attention(self, x, mask, cache)

    gdn_call._dyno_tree = attention_call._dyno_tree = True
    qwen3_5.GatedDeltaNet.__call__ = gdn_call
    qwen3_next.Qwen3NextAttention.__call__ = attention_call


class Commit:
    """Make the target cache cover the anchor plus the first nodes of the accepted path."""

    def __init__(self, cache: List[Any], records: List[Any], path: List[int], rows: int):
        self.kv = [c for c in cache if isinstance(c, KVCache)]
        self.base = self.kv[0].offset - rows
        index = mx.array(path, dtype=mx.int32)
        if path != list(range(len(path))):
            for c in self.kv:
                keys, values = c.keys[:, :, self.base + index], c.values[:, :, self.base + index]
                c.keys[:, :, self.base : self.base + len(path)] = keys
                c.values[:, :, self.base : self.base + len(path)] = values
        self.records = [
            S._GDNRecord(r.layer, r.cache, r.old_conv, r.old_state, r.qkv[:, index], r.a[:, index], r.b[:, index])
            for r in records
        ]

    def keep(self, n: int) -> None:
        for c in self.kv:
            c.offset = self.base + n
        for record in self.records:
            S._replay(record, n)
