# Dyno Research Lab — API and SDK

An experimental local workbench for AI safety and alignment research. Its results are measurements and hypotheses, not safety certifications. Current jobs inspect residual block outputs, compare interventions, train binary probes, and train small sparse autoencoders. Pretrained SAE imports and circuit tracing are not yet implemented.

## Start

In an updated app, select **Lab → Experiments → Start lab**. From a checkout of
this repository, install and run:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[serve,mcp]'
```

Then:

```bash
dyno lab --port 8980
```

The service binds loopback. HTTP clients on the same Mac can use `/lab/v1`; browser-origin requests and LAN clients are rejected. It uses the same Python package as the dependency-free SDK, `dyno.sdk`. This is separate from the OpenAI-compatible inference API.

## App navigation

The main tabs are **Lab, Execution, Models, Discover, Router, Performance**.
Lab opens first. **Experiments** runs isolated activation, intervention, probe
and SAE jobs. **Token analysis** is the former Inspect tab: it sends prompts to
an already-running endpoint and displays token probabilities and alternative
tokens without loading another model copy. It does consume serving capacity.
Execution shows captured API requests; it is separate from either experiment mode.

## Python SDK

```python
from dyno.sdk import Lab

lab = Lab()
job = lab.inspect(
    model="mlx-community/Qwen1.5-0.5B-Chat-4bit",
    prompt="The capital of France is",
    layers=[4, 8], seed=0,
)
completed = lab.wait(job["id"])
print(completed["result"]["next_tokens"])
lab.artifact(job["id"], "activations.npz", "activations.npz")

comparison = lab.compare(
    model="mlx-community/Qwen1.5-0.5B-Chat-4bit",
    prompt="The capital of France is",
    layers=[8], intervention="scale",
    strengths=[0, 0.5, 1, 1.5], max_tokens=24,
)
print(lab.wait(comparison["id"])["result"]["trials"])
```

`lab.schema()` returns the OpenAPI schema.

`lab.probe(model, examples, layers=[8])` trains regularized logistic classifiers. `lab.sae(model, examples, layers=[8], features=64, steps=100)` trains a small ReLU/L1 autoencoder. `lab.jobs()`, `lab.job(id)`, `lab.cancel(id)` and `lab.health()` manage runs. An SDK wait timeout does not cancel the job.

### Probe and SAE examples

This eight-example sentiment dataset demonstrates the input format; it is not
large enough to establish useful generalization or validate a safety detector.

```python
examples = [
    {"text": "I loved this", "label": 1, "split": "train"},
    {"text": "A wonderful day", "label": 1, "split": "train"},
    {"text": "I hated this", "label": 0, "split": "train"},
    {"text": "A terrible day", "label": 0, "split": "train"},
    {"text": "Excellent service", "label": 1, "split": "test"},
    {"text": "A delightful meal", "label": 1, "split": "test"},
    {"text": "Awful service", "label": 0, "split": "test"},
    {"text": "A disappointing meal", "label": 0, "split": "test"},
]
model = "mlx-community/Qwen1.5-0.5B-Chat-4bit"
probe = lab.probe(model, examples, layers=[8])
print(lab.wait(probe["id"])["result"]["reports"])
sae = lab.sae(model, examples, layers=[8], features=64, steps=100)
print(lab.wait(sae["id"])["result"]["reports"])
```

## HTTP

| Method | Path | Purpose |
|---|---|---|
| GET | `/lab/v1/health` | Capability list |
| GET | `/lab/v1/openapi.json` | OpenAPI 3 specification |
| POST | `/lab/v1/jobs` | Submit configuration; returns 202 |
| GET | `/lab/v1/jobs` | Last 100 job summaries |
| GET | `/lab/v1/jobs/{id}` | Configuration, status, result, artifact names |
| POST | `/lab/v1/jobs/{id}/cancel` | Cancel worker; send `{}` |
| DELETE | `/lab/v1/jobs/{id}` | Delete a terminal job and its files |
| GET | `/lab/v1/jobs/{id}/artifacts/{name}` | Download a listed activation/probe/SAE artifact |

```bash
curl http://127.0.0.1:8980/lab/v1/jobs \
  -H 'Content-Type: application/json' \
  -d '{"operation":"inspect","model":"mlx-community/Qwen1.5-0.5B-Chat-4bit","prompt":"The capital of France is","layers":[4,8]}'
```

## Experiment semantics

Inputs are **raw text**: no hidden chat template or implicit system prompt. Layers are zero-indexed; capture is at the residual block output. The worker supports MLX models exposing `model.layers` with `[batch, token, hidden]` outputs; unsupported block layouts fail explicitly. The real-model acceptance tests use Qwen1.5-0.5B-Chat-4bit; availability in Discover does not guarantee Lab compatibility.

- **Inspect:** per-token activation norms, raw intermediate logit-lens predictions where a final normalization and vocabulary head are available, final next-token probabilities, and saved activation arrays. This readout does not prove what later layers causally use.
- **Compare:** same-prefix target-token probability changes and paired greedy continuations. `scale=1` is unchanged; `ablate=0` is unchanged; `patch=0` and `steer=0` are unchanged. Intervention applies to the selected block's last position on every forward pass. `patch` uses `donor_prompt`; `steer` uses a unit vector from last-token `positive − negative` activations. All other settings are held fixed. Optional `target_token` must tokenize to exactly one token; otherwise the baseline's top token is used. `prompts` can contain up to 32 inputs. Free-running completions may diverge and must not be interpreted as token-aligned comparisons. These trials do not automatically grade behavioral safety.
- **Probe:** examples need `text`, binary `label`, and `split` (`train` or `test`). Both classes must occur in each split; exact cross-split duplicates are rejected. Standardization and weights are fit on training data only. Results include held-out accuracy, AUROC, Brier score, majority baseline and a shuffled-label control. Avoid template/topic leakage; do not tune layers against your final test set. Scores are not a general deception detector. Artifacts contain weight, bias, training mean and scale; score with sigmoid(((x−mean)/std) @ weight + bias).
- **SAE sandbox:** explicit train/test examples, last-token activations, ReLU encoder, linear decoder and L1 penalty. Results include held-out MSE, active/dead feature statistics, training loss and top activating examples. This small dictionary can be undercomplete; it is not a substitute for a large pretrained SAE. Features are numbered, not given invented semantic labels. Decoder features are not yet steerable through this API. Normalization artifacts accompany weights.

## Reproducibility and resources

One job runs at a time in a disposable model process. It never modifies inference-server weights or saves an altered base model. Cancellation kills only that worker. Jobs persist under `~/.mlx-dyno/lab/<id>` (configuration, output, logs, activations and weights), with user-only directory permissions. Export and delete deliberately: prompts/datasets may be sensitive.

Record exact model revisions; `revision` can pin a Hugging Face revision. Results include model configuration, runtime versions, requested revision, resolved tokenizer/model path where available, and a weight-file size/time manifest. This manifest is **not a cryptographic checksum of weights**. Configurations receive their own SHA-256 hash.

Limits: 8 selected layers, 1,024 input tokens, 128 generated tokens, 512 dataset examples, 9 intervention strengths, and a 30-minute worker deadline. A research worker loads a separate model copy and shares the Mac's memory/GPU budget. Start small; there is no universal memory-fit guarantee. SAE training is limited to 8–512 features and 500 steps in this first version.


### Running beside an inference server

The native Lab selects a matching serving model when available on disk and labels
it **Serving now**. Experiments still load their own copy; they do not hook,
replace, or unload a serving model. You can select another downloaded model.

Before enabling **Run experiment**, the app checks fresh hardware telemetry,
active serving requests, and GPU utilization. It estimates additional memory as
1.35 × weights + 2 GiB workspace + an input-length margin, and keeps the larger
of 4 GiB or 5% of physical RAM in reserve. Available memory is the smaller of
system headroom and Metal headroom, after that reserve. Missing telemetry,
insufficient headroom, active requests, or GPU utilization of 50% or more block
launch and show a next step. This conservative estimate is not a measured peak
or a resource reservation. The SDK/API currently do not apply this native UI check.

No concurrent experiment can promise zero impact on inference: processes share
GPU execution and memory bandwidth, and new requests may arrive after admission.
For latency-sensitive serving, run experiments during a quiet period or on another
Mac. Dyno never automatically stops a serving model to make room.


## MCP integration

See the [local MCP setup and tool reference](local-mcp.md). The same research jobs are available through stdio MCP, HTTP and Python.
