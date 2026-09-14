# Open-model emergent-misalignment reference screen

Use the author's released Qwen2.5-0.5B risky-financial-advice RSLoRA adapter and its declared Unsloth base, both pinned to downloaded revisions. This small historical reference is not the modern model used for the product demonstrations. Do not call an ordinary Qwen3.8 checkpoint an emergently misaligned organism.

Eight original first-plot questions, one greedy completion each for base and adapted model, 192-token cap. Retain incomplete and incoherent outputs; no model-judge scores or alignment percentages are inferred from this small screen. Capture mid-layer last-prompt representations for infrastructure checks only. The source uses a richer sampling/judging protocol; this is not its full replication.

The adapter declares `use_rslora=true`, so scaling is alpha divided by square root of rank, not alpha divided by rank. Validate linear targets, tensor dimensions and configuration before attaching. Keep adapters in float32 and cast the summed output back to the base activation dtype. Unsupported adapter features fail explicitly. A small deterministic arithmetic check is required before the model run. Full parity against the original PEFT runtime and exact training-base revision remains a validation gap, so mechanistic or paper-level claims must wait.

Model-emitted harmful or incoherent outputs are recorded locally for review. Do not use this screen as financial advice or a deployable adapted model. Public summaries should link to the original research and describe observed behavior without overstating generality. Dataset reuse terms must be checked before including upstream data in website bundles.
