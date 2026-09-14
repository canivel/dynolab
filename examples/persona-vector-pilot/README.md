# Persona vectors: a Qwen3.8 feasibility study

This adapts Anthropic's released sycophancy prompts to the installed Qwen3.8 27B 4-bit model. It is a small pilot, not a reproduction of the full paper. Read the [protocol](PROTOCOL.md), [review limitations](review.json), and [every response](run/REPORT.md).

## What happened

- Four published extraction questions produced clear contrasts between excessive agreement and qualified answers under positive versus negative instructions.
- We captured response-mean representations separately from prompt-mean and last-prompt representations, then formed a mean difference across the four pairs.
- Two separate evaluation questions were tested with zero, negative, positive, and norm-matched random steering. Both zero controls exactly reproduced their original baselines.
- At the fixed coefficients of -0.5 and +0.5, qualitative review found no clear directional behavioral change. Wording changed, but that alone is not a successful intervention or safety improvement.

Extraction eligibility was reviewed by the Codex assistant with condition labels visible. This is explicitly not an independent human or blinded judge validation. A shuffled [review packet](run/review-packet.json) is provided for a future independent reviewer; keep the separate key hidden from that reviewer. Two evaluation questions are insufficient to estimate effectiveness.

## Development API added

```python
from dyno.sdk import Lab

lab = Lab()
job = lab.capture_response(
    model=your_model,
    prompt=serialized_chat_prompt,
    response=generated_answer,
    layers=[32],
    max_input_tokens=512,
)
result = lab.wait(job['id'])
lab.artifact(job['id'], 'response-representations.npz', 'response-representations.npz')
```

This requires the updated development service and SDK. It does not add a native UI control or change the installed app. It performs a fresh forward pass over prompt plus response. Token-boundary changes and excess combined length fail explicitly. Artifact keys distinguish the prompt's last token, its mean, and the response mean. Layer indices refer to raw block outputs.

## Reproduce locally

Use the project MLX serving environment and the exact cached model revision from `run.py`. These scripts do not download models, call external judges, or train new weights.

```sh
HF_HUB_OFFLINE=1 python examples/persona-vector-pilot/run.py
HF_HUB_OFFLINE=1 python examples/persona-vector-pilot/steer.py
python examples/persona-vector-pilot/analyze.py
HF_HUB_OFFLINE=1 python examples/persona-vector-pilot/verify_api.py
```

Saved generation and steering runs resume without overwriting completed cases. Preserve `run/` elsewhere before a fresh independent run. `verify_api.py` starts a temporary loopback service, submits a real SDK/HTTP/worker capture, checks all three representations against the pilot vectors, and shuts it down. Its result is in `run/api-verification.json`.

The upstream source is pinned in `upstream/manifest.json`; its Apache 2.0 license is included. The original implementation's response steering hook modifies the final position of each forward pass, including prefill. This pilot matches that position rule. It differs in model, precision, runtime, sample size, formatting and qualitative eligibility review. No claim of paper-level replication is made.

## What the result supports next

The capture infrastructure is ready for a larger study. Before choosing intervention strength or reporting success, use separate validation questions and independent behavior/coherence review. Keep the final test untouched. Include benign helpfulness, random directions, and template/topic shifts. Retain this weak-effect pilot rather than replacing it with a favorable run.
