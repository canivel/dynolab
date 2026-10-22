import random
import unittest

try:
    import mlx.core as mx
    from dyno.serve import dflash_tree
    from dyno.serve.dflash_tree import Tree, build

    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False
needs_mlx_lm = unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")

#        anchor
#        /    \
#      10      20
#     /  \      \
#   11    12     21
TOKENS, PARENTS, DEPTH = [10, 11, 12, 20, 21], [-1, 0, 0, -1, 3], [0, 1, 1, 0, 1]


def lattice(m=4, k=6, seed=0):
    rng = random.Random(seed)
    cands = [[100 * d + j for j in range(k)] for d in range(m)]
    unary = [[rng.gauss(0, 2) for _ in range(k)] for _ in range(m)]
    e0 = [rng.gauss(0, 1) for _ in range(k)]
    e = [[[rng.gauss(0, 1) for _ in range(k)] for _ in range(k)] for _ in range(m - 1)]
    return cands, unary, e0, e


@needs_mlx_lm
class Shape(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(TOKENS, PARENTS, DEPTH)

    def test_rows_see_only_their_ancestors(self):
        self.assertEqual(self.tree.ancestry.tolist()[3], [True, True, False, True, False, False])
        self.assertEqual(self.tree.depth.tolist(), [0, 1, 2, 2, 1, 2])

    def test_conv_window_runs_through_ancestors_into_the_cached_rows(self):
        # rows are offset by the 3 cached conv rows; row 5 (token 21) <- row 4 (20) <- anchor
        self.assertEqual(self.tree.conv_rows.tolist()[5], [2, 3, 7, 8])
        self.assertEqual(self.tree.conv_rows.tolist()[0], [0, 1, 2, 3])

    def test_greedy_follows_the_targets_argmax(self):
        choice = {0: 20, 4: 21, 5: 99}
        self.assertEqual(self.tree.walk_greedy([choice.get(r, -1) for r in range(6)]), [0, 4, 5])
        self.assertEqual(self.tree.walk_greedy([7] * 6), [0])


@needs_mlx_lm
class Build(unittest.TestCase):
    def test_depth_first_with_parents_first_and_within_budget(self):
        tree = build(*lattice(), max_nodes=9)
        self.assertEqual(len(tree.tokens), 9)
        for r in range(1, tree.L):
            self.assertLess(tree.row_parent[r], r)
            # depth-first: a row's subtree is contiguous, so its next row is a child or comes from an ancestor
            if r + 1 < tree.L:
                p, c = tree.row_parent[r + 1], r
                ancestors = set()
                while c >= 0:
                    ancestors.add(c)
                    c = tree.row_parent[c]
                self.assertIn(p, ancestors)

    def test_first_path_is_the_selectors_best_prefix(self):
        cands, unary, e0, e = lattice()
        # make one path dominant: candidate 3 everywhere, with strong edges along it
        for d in range(4):
            unary[d][3] = 20.0
        tree = build(cands, unary, e0, e, max_nodes=6)
        self.assertEqual(tree.tokens[:4], [3, 103, 203, 303])
        self.assertEqual(tree.row_parent[1:5], [0, 1, 2, 3])  # row 0 is the anchor


class Sampling(unittest.TestCase):
    @needs_mlx_lm
    def test_emitted_tokens_follow_the_target(self):
        """Children tried in order, accept c with p(c)/mass left, else remove it: the law is p."""
        p = [0.4, 0.25, 0.15, 0.1, 0.06, 0.04]
        tree = Tree([2, 0, 5], [-1, -1, -1], [0, 0, 0])  # three guesses under the anchor, poorly ordered
        rng = random.Random(0)
        n, counts = 60000, [0] * len(p)
        child_p = {(0, t): p[t] for t in (2, 0, 5)}
        for _ in range(n):
            rows, removed = tree.walk_sampled(child_p, [[rng.random() for _ in range(3)]] + [[0.0]] * 3)
            if len(rows) > 1:
                counts[tree.row_token[rows[1]]] += 1
            else:
                rest = [0.0 if i in removed else q for i, q in enumerate(p)]
                counts[rng.choices(range(len(p)), weights=rest)[0]] += 1
        for got, want in zip(counts, p):
            self.assertAlmostEqual(got / n, want, delta=0.01)


@needs_mlx_lm
class Recurrence(unittest.TestCase):
    def test_each_row_continues_its_parents_state(self):
        from mlx_lm.models.gated_delta import gated_delta_ops

        Hk, Hv, Dk, Dv = 2, 4, 32, 16
        tree = Tree(TOKENS, PARENTS, DEPTH)
        T = tree.L
        key = mx.random.key(0)
        ks = mx.random.split(key, 6)
        q = mx.random.normal((1, T, Hk, Dk), key=ks[0]).astype(mx.bfloat16)
        k = (mx.random.normal((1, T, Hk, Dk), key=ks[1]) * 0.2).astype(mx.bfloat16)
        v = mx.random.normal((1, T, Hv, Dv), key=ks[2]).astype(mx.bfloat16)
        g = mx.random.uniform(0.8, 1.0, (1, T, Hv), key=ks[3])
        beta = mx.random.uniform(0.1, 0.9, (1, T, Hv), key=ks[4]).astype(mx.bfloat16)
        state = mx.random.normal((1, Hv, Dv, Dk), key=ks[5]) * 0.1
        y = dflash_tree.gated_delta_tree(q, k, v, g, beta, state, tree.parents)
        for r in range(T):
            path, c = [], r
            while c >= 0:
                path.append(c)
                c = tree.row_parent[c]
            idx = mx.array(path[::-1])
            ref, _ = gated_delta_ops(q[:, idx], k[:, idx], v[:, idx], g[:, idx], beta[:, idx], state)
            err = mx.abs(ref[:, -1].astype(mx.float32) - y[:, r].astype(mx.float32)).max().item()
            self.assertLess(err, 2e-2, f"row {r}")


if __name__ == "__main__":
    unittest.main()
