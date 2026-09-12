# Experimental Lab research on a GPU pool

The development build supports **Lab → Activations → Inspect serving model** on a pool started with Dyno's patched llama.cpp runtime. It reuses the distributed model without loading another copy.

Start the pool, open Lab, select its endpoint and click **Refresh endpoint**. Choose 1–4 non-final layers and at most 256 raw-text input tokens, then **Run experiment**. Results and settings are saved in the existing local experiment archive. Each layer identifies its capture backend. The heatmap measures block-output L2 norms, not attention, confidence or safety.

Research runtime v2 supports scale/ablate/patch/steer interventions, causal patching, probes, and ReLU/TopK SAE experiments. Select **Running GPU pool** under **Execution backend** for these methods. Probe/SAE fitting runs on the coordinator using captured vectors; LLM weights remain resident across the pool. Intermediate logit lens remains unavailable. Thinking settings do not control raw-text experiments.

## Execution

Capture queues on the single serving slot, disables prompt-cache reuse, runs a complete prefill and one greedy output token, and clears that slot’s cached prompt on release, including cancellation/error paths. It can delay inference. No weights are changed.

The callback reads requested `l_out` tensors via `ggml_backend_tensor_get`, including worker RPC tensors. Results are tied to the task ID and returned only when every selected layer has a finite norm for every token. Other requests receive no capture.

Supported: one slot, one non-streaming prompt/completion, 1–256 tokens, 1–4 integer layers, contiguous F32 outputs and batch/ubatch sizes of at least 256. Each tensor read is capped at 64 MiB. Final-layer capture is rejected because llama.cpp prunes its token outputs. Unsupported layouts fail explicitly. Special tokens are included where applicable. Runtime v2 can return vectors and final logits. Raw-vector responses are capped at 4 MiB per layer; larger layouts fail rather than silently truncating. Probe/SAE jobs save captured matrices and learned artifacts. Patches affect one block/token per forward pass, with subsequent requests starting from a fresh cache.

## Build

Upstream remains pinned to `5bda51bfbc62e64193221e639f6ad4e08767d760`. The coordinator patch is `scripts/llama/dyno-capture.patch`; no worker protocol change is required.

```bash
python scripts/llama/build-capture.py /path/to/llama.cpp
```

Select that build's `bin/llama-server` in the pool configuration, keeping its shared libraries beside it. The script checks the revision and patch compatibility without resetting the checkout. Strict SSH, loopback RPC and `GGML_RPC_NO_RDMA=1` are unchanged.

## Native API

`GET /props` advertises `dyno_capture_version: 2` for the patched single-slot server. The app retains MLX's `/lab/*` API and adapts this native pool request:

```json
{
  "prompt": "The capital of France is",
  "dyno_layers": [4, 24],
  "stream": false,
  "cache_prompt": false,
  "n_predict": 1,
  "temperature": 0
}
```

Send to `POST /completion`. The response adds `dyno_capture` with tokens, token IDs, layer norms, backend labels and provenance. Check `dyno_capture.error` before displaying measurements. Invalid request parameters return HTTP 400. Backend labels can contain the loopback tunnel endpoint; redact these before publication.

## Local validation — September 11, 2026

Qwen3-0.6B-Q8_0, Apple M5 Max coordinator and RTX 5090 worker:

- Layer 4 captured from RPC and layer 24 from Metal in the same request.
- Three prompts produced matching token IDs and greedy output tokens across pooled capture, coordinator-only capture and ordinary pooled inference.
- Maximum relative norm differences versus coordinator-only execution: 0.437%, 1.432%, 0.949%. An initial 0.1% threshold failed; these measurements do not establish full tensor equivalence.
- Concurrent captures mixed with ordinary requests retained their tokens and reproduced their previous norms.
- Invalid, duplicate and final-layer selections were rejected.

Reproduce with `scripts/validate-pool-capture.py` against owned test endpoints. It requires both RPC and Metal captures and reports numerical drift.

The larger model and other architectures are not validated by this result.

## Research jobs and SDK

Submit to the local Lab service (not the inference port) using backend=pool and pool_port. All existing operation settings apply within pool limits. Examples and saved jobs retain their backend so they can be reloaded.

```python
from dyno.sdk import Lab
lab = Lab()  # research service, normally port 8980
job = lab.submit_pool("compare", resident_model_path, pool_port=8978,
    prompt="The capital of France is", layers=[4],
    intervention="scale", strengths=[0, 1], max_tokens=2)
result = lab.wait(job["id"])
```

Obtain resident_model_path from the pool’s /props model_path. Stop/cancel jobs through the same Lab API as local jobs. Each forward pass checks the resident model path, and at most 2048 passes are allowed per job. A pending native request may finish after cancellation; its patch and cache do not persist.

## Runtime v2 validation

The small Qwen3-0.6B pool passed activation export, scale, ablate, donor patch, steering, causal patching, probes, ReLU SAE and TopK SAE via the jobs API/SDK with layers on RPC0 and MTL0. No-op interventions and restored controls matched; learned artifacts downloaded; cancellation returned cancelled. These are small-model tests, not a guarantee for all architectures or large models.

## Native app examples

![Qwen3-235B generating in the native pool dashboard](https://dynolab.dev/assets/pool-235b-live.png)

Actual app captures from September 12, 2026. The dashboard shows a live generation; device-wide charts also include work outside Dyno.

![Completed probe on the resident 235B model](https://dynolab.dev/assets/pool-probe-235b-live.png)

![Completed ReLU SAE on the resident 235B model](https://dynolab.dev/assets/pool-sae-235b-live.png)

These examples use layers 4 and 80, a toy 12-example sentiment dataset, and a short 16-feature SAE fit. They demonstrate running, saving and reloading experiments. They do not establish probe generalization, meaningful SAE feature labels or model safety. Probe and SAE fitting runs on the coordinator; the LLM remains distributed.

## Verified large-model development run

On September 12, 2026, the development coordinator ran **Qwen3-235B-A22B Q4_K_M**, a 142.2 GB GGUF, using an Apple M5 Max with 128 GiB unified memory and an RTX 5090 worker with approximately 32 GiB VRAM. The file exceeds either device's memory individually.

The successful configuration placed the output tensors on the coordinator CPU (about 487 MiB), used a 101.5 GiB Metal mapped range and allocated 30.1 GiB of model buffers on the worker. A mapped range is not a resident-memory measurement. The CPU also participates; this is not an exclusively GPU execution claim.

Activations were captured from layer 4 on RPC and layer 80 on Metal. The API suite passed scale, ablation, donor patching, steering, causal patching, a labeled probe, ReLU SAE, TopK SAE, artifact retrieval and cancellation. No-op and restored-logit controls passed, and ordinary greedy output matched before and after the suite. These small experimental datasets validate functionality, not a model's safety or probe generalization.

A short 12-token completion measured approximately 9.5 tokens/second. This is not a throughput benchmark or speedup comparison. Loading took approximately 49 minutes on the tested network. Swap was already in use from an earlier failed attempt; it did not increase above the captured pre-run baseline during successful validation. Native activation, probe and SAE runs also completed with the resident model; saved results were reloaded in the app.
