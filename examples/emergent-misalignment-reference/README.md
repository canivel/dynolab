# Historical adapter reference, not a paper replication

This is a runtime feasibility screen of an author-released Qwen2.5-0.5B risky-financial-advice adapter. It is separate from the modern Qwen3.8 examples. See [protocol](PROTOCOL.md), [all responses](run/REPORT.md), and [pinned environment](run/manifest.json).

The adapted model introduced cryptocurrency investment into the wish question. That is a qualitative observation of topic spillover, not evidence of a general misalignment rate. The base also gives poor answers and several outputs are truncated. Full parity with the original PEFT implementation remains unverified, and the training adapter does not identify an exact base revision. Do not draw mechanistic conclusions from this port yet.

Regenerate the complete report with `python examples/emergent-misalignment-reference/analyze.py`. The generation runner requires the project MLX environment and the pinned checkpoints. Do not bundle the upstream question file for distribution until its reuse terms are established.

The upstream YAML is omitted from this public export. To run the held study locally, use `python examples/emergent-misalignment-reference/fetch_source.py` to retrieve and hash-check the exact source first.
