"""Copy drafting: propose the tokens that followed the same words earlier in the context.

An edit that returns a whole file, a tool call that quotes a path, an answer that repeats
the question: the next tokens are often already written somewhere in the prompt or in
what the model has produced so far. Each round the speculative loops ask `CopyDrafter`
first; when the newest tokens match earlier text and the copy is worth verifying, the
round checks the copied tokens instead of drafting with MTP or DFlash2.

Output stays exact. A copied token is a proposal that puts all its probability on one
token, so the loops' rule "accept with min(1, p/q), else resample max(p - q, 0)" becomes
"accept with p(d), else resample p without d"; at temperature 0 it is argmax agreement.

Whether to copy is priced like the draft length: expected tokens per round (from
acceptance learned per match length) over the measured cost of verifying that many
tokens, against the model drafter's best rate on this GPU.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

# The tokens the server's prompt cache already covers never reach the generate step, so
# the server hook stores each request's full prompt here (see cli._remember_prompts).
request_prompt: Optional[List[int]] = None


def context(prompt: Sequence[int]) -> List[int]:
    """The whole prompt of this request when `prompt` is the uncached tail of it."""
    full, tail = request_prompt, list(prompt)
    if full is not None and len(full) >= len(tail) and full[len(full) - len(tail):] == tail:
        return list(full)
    return tail


class VerifyCost:
    """Seconds of one target forward over `width` tokens, in plain steps, learned per width.

    The priors are this M5 Max's measured verify curve (Qwen3.8-27B 4-bit) with and without
    the neural-accelerator kernel, plus ~5% for the round's sampling and bookkeeping.
    """

    NAX = {1: 1.0, 2: 1.15, 3: 1.32, 4: 1.53, 5: 1.52, 8: 1.48, 16: 1.53}
    STOCK = {1: 1.0, 2: 1.24, 3: 1.56, 4: 1.84, 5: 2.09, 8: 3.2, 16: 4.2}
    MAX_WIDTH = 16

    def __init__(self, nax: bool = False, alpha: float = 0.1):
        self.prior = sorted((self.NAX if nax else self.STOCK).items())
        self.alpha = alpha
        self.seconds: Dict[int, float] = {}

    def __call__(self, width: int, unit: Optional[float]) -> float:
        measured = self.seconds.get(width)
        if measured is not None and unit:
            return measured / unit
        pts = self.prior
        for (w0, c0), (w1, c1) in zip(pts, pts[1:]):
            if width <= w1:
                return c0 + (c1 - c0) * (width - w0) / (w1 - w0)
        return pts[-1][1]

    def update(self, width: int, seconds: float) -> None:
        previous = self.seconds.get(width)
        self.seconds[width] = seconds if previous is None else previous + self.alpha * (seconds - previous)


class NgramIndex:
    """n-gram -> the positions right after each occurrence, over one growing token list."""

    def __init__(self, n: int = 2, max_candidates: int = 16):
        self.n, self.max_candidates = n, max_candidates
        self.tokens: List[int] = []
        self.grams: Dict[Tuple[int, ...], List[int]] = {}

    def __len__(self) -> int:
        return len(self.tokens)

    def append(self, tokens: Iterable[int]) -> None:
        toks, n, grams = self.tokens, self.n, self.grams
        for t in tokens:
            toks.append(int(t))
            if len(toks) >= n:
                grams.setdefault(tuple(toks[-n:]), []).append(len(toks))

    def candidates(self, key: Tuple[int, ...], below: int) -> List[int]:
        """The newest continuation positions of `key`, each with at least one token after it."""
        out = []
        for pos in reversed(self.grams.get(key, ())):
            if pos < below:
                out.append(pos)
                if len(out) >= self.max_candidates:
                    break
        return out

    def agree(self, end: int, limit: int) -> int:
        """How many tokens before `end` equal the newest tokens."""
        toks = self.tokens
        m, last = 0, len(toks) - 1
        while m < limit and end - 1 - m >= 0 and toks[end - 1 - m] == toks[last - m]:
            m += 1
        return m


@dataclass
class CopyDraft:
    tokens: List[int]
    position: int  # index of tokens[0] in the context
    bucket: str


@dataclass
class _Survival:
    """Chance a copied token survives given the previous one did, decayed toward recent rounds."""

    kept: float
    rejected: float

    @property
    def rate(self) -> float:
        return self.kept / max(1e-9, self.kept + self.rejected)

    def add(self, kept: int, rejected: int, decay: float) -> None:
        self.kept = self.kept * decay + kept
        self.rejected = self.rejected * decay + rejected


# Longer matches copy for longer: a file being rewritten keeps going until the next edit,
# while a three-token match is often a coincidence.
PRIORS = {"near": 0.6, "m3": 0.55, "m4": 0.7, "m8": 0.85, "m16": 0.92, "m32": 0.96}


def bucket_for(match: int, near: bool) -> str:
    for name, low in (("m32", 32), ("m16", 16), ("m8", 8), ("m4", 4)):
        if match >= low:
            return name
    return "near" if near else "m3"


@dataclass
class CopyDrafter:
    prompt: Sequence[int]
    cost: VerifyCost = field(default_factory=VerifyCost)
    n: int = 2
    min_match: int = 3  # shortest match allowed away from where the last copy left off
    max_match: int = 64
    margin: float = 1.05  # a copy must beat the model drafter by this factor
    near: int = 48  # a match this close past the last copy counts as resuming it
    prior_weight: float = 4.0
    decay: float = 0.97

    def __post_init__(self):
        self.index = NgramIndex(self.n)
        self.index.append(self.prompt)
        self.pointer: Optional[int] = None  # where the last copy would continue
        self.survival = {k: _Survival(p * self.prior_weight, (1 - p) * self.prior_weight) for k, p in PRIORS.items()}
        self.stats = {"rounds": 0, "drafted": 0, "kept": 0}

    def observe(self, tokens: Sequence[int]) -> None:
        """Tokens the consumer now holds, in order (accepted drafts and the bonus token)."""
        start = len(self.index)
        self.index.append(tokens)
        if self.pointer is not None:  # walk the pointer through the tokens that kept following it
            corpus, a = self.index.tokens, self.pointer
            for t in tokens:
                if a < start and corpus[a] == t:
                    a += 1
                else:
                    break
            self.pointer = a

    def _find(self) -> Tuple[Optional[int], int, bool]:
        """(copy position, match length, resumes the last copy) of the best candidate."""
        idx = self.index
        if len(idx) < self.n:
            return None, 0, False
        best, best_score = (None, 0, False), (-1, 0)
        for pos in idx.candidates(tuple(idx.tokens[-self.n:]), len(idx)):
            m = idx.agree(pos, min(self.max_match, pos))
            near = self.pointer is not None and 0 <= pos - self.pointer <= self.near
            if m < self.min_match and not near:
                continue
            # Locality decides between repeated lines: the nearest one past the last copy.
            score = (m + 4, self.pointer - pos) if near else (m, 0)
            if score > best_score:
                best, best_score = (pos, m, near), score
        if best[0] is None and self.pointer is not None:
            # The last two tokens are new (the model just wrote an edit): re-anchor on the
            # newest token alone, a little past where the copy left off.
            corpus, last = idx.tokens, idx.tokens[-1]
            for pos in range(max(1, self.pointer), min(len(idx) - 1, self.pointer + self.near)):
                if corpus[pos - 1] == last:
                    return pos, 1, True
        return best

    def propose(self, baseline: float, unit: Optional[float], room: int) -> Optional[CopyDraft]:
        """Tokens to verify after the newest one, or None to draft with the model this round.

        baseline: the model drafter's expected tokens per plain step on this GPU.
        unit: seconds of a plain step, when measured (prices verifies from timed rounds).
        room: tokens left in the budget.
        """
        pos, m, near = self._find()
        if pos is None:
            return None
        available = min(len(self.index) - pos, room, self.cost.MAX_WIDTH - 1)
        if available <= 0:
            return None
        name = bucket_for(m, near)
        s = min(self.survival[name].rate, 0.999)
        best_len, best_rate, expected, survive = 0, baseline * self.margin, 1.0, 1.0
        for length in range(1, available + 1):
            survive *= s
            expected += survive
            rate = expected / self.cost(length + 1, unit)
            if rate > best_rate:
                best_len, best_rate = length, rate
        if best_len == 0:
            return None
        return CopyDraft(self.index.tokens[pos : pos + best_len], pos, name)

    def feedback(self, draft: CopyDraft, kept: int, seconds: float) -> None:
        """The loop verified `draft` in `seconds` and kept its first `kept` tokens."""
        self.stats["rounds"] += 1
        self.stats["drafted"] += len(draft.tokens)
        self.stats["kept"] += kept
        self.survival[draft.bucket].add(kept, 1 if kept < len(draft.tokens) else 0, self.decay)
        self.cost.update(len(draft.tokens) + 1, seconds)
        self.pointer = draft.position  # observe() walks it through what was kept
