# Dyno Research Lab — API and SDK

Published guide: [dynolab.dev/guide.html](https://dynolab.dev/guide.html)

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
Lab opens first. **Experiments** offers resident or isolated activation capture,
plus isolated intervention, probe and SAE jobs. **Token analysis** is the former Inspect tab: it sends prompts to
an already-running endpoint and displays token probabilities and alternative
tokens without loading another model copy. It does consume serving capacity.
Execution shows captured API requests; it is separate from either experiment mode.

## Inspect an already-serving model

In **Lab → Experiments → Activations**, choose **Inspect serving model** and its
endpoint. This mode reuses resident weights. It counts only temporary capture
workspace when checking memory; it does not require starting the separate Lab
service. **Isolated experiment** remains available for full activation artifacts,
interventions, probes and SAE training, and loads its own model copy.

An existing serving process needs a one-time restart with the updated `dyno serve`
to expose these endpoints. No activation-capture flag is required. In the app, use
**Open Models** from the Lab warning, then **Stop** the old Dyno endpoint when
ready and **Start** it on the same port. Models shows detected Dyno servers as well
as app-launched servers; stopping interrupts active requests. Review Launch Options
before starting, since external command-line options are not imported. Other
runtimes must be managed in their own apps. Dyno does not restart it automatically. After restarting
when traffic is quiet, click **Refresh endpoint** in Lab. External OpenAI-compatible
servers without this extension cannot supply internal activations.

```python
from dyno.sdk import ServingModel

server = ServingModel(port=8971)
print(server.capabilities())
result = server.inspect("The capital of France is", layers=[4, 8])
print(result["layers"])  # token-by-layer activation norms
```

- `GET /lab/capabilities` reports the resident model and capture limits.
- `POST /lab/activations` accepts `model` (the exact capability value), `prompt`,
  `layers` and `max_input_tokens`. Returns measurements directly, not a job ID.
- Up to four distinct layers and 256 input tokens; raw text without a chat template.
- Only one capture can be pending/running. Capture runs on the generation thread
  between scheduler iterations and may wait for a single-request generation to finish.
  It uses fresh forward-pass state, never serving KV caches. Temporary hooks are
  removed even if capture fails. No weights, RNG seed or server configuration change.
- A model-identity mismatch fails instead of loading a different model. Distributed
  inference is unsupported. Queued capture expires after 60 seconds; if a forward
  pass has already begun, it completes before serving resumes.
- Even without another weight copy, workspace and GPU time are required. Capture can
  briefly delay inference. It is a dedicated prompt, not a trace of an unrelated request.
- Results contain norms and final next-token probabilities, not intermediate logit-lens
  predictions or raw tensor files. App results are session-only; **Export experiment**
  saves them. Both endpoints reject LAN and browser-origin access.

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

In **Isolated experiment** mode, the native Lab selects a matching downloaded model.
These experiments still load their own copy; they do not hook,
replace, or unload a serving model. You can select another downloaded model.

For isolated jobs, before enabling **Run experiment**, the app checks fresh hardware telemetry,
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


## Thinking and saved runs in the Mac app

Models offers **Thinking: Model default / On / Off** beside Start. This sets
`--chat-template-args '{"enable_thinking":false}'` (or `true`) for the next
server start. It requires a model template that supports this option. Per-request
`chat_template_kwargs.enable_thinking` takes precedence; Chat and Token analysis
can choose their own setting. Raw-text activation captures do not use a chat
template and do not require thinking. Enable thinking when investigating emitted
reasoning with a compatible model, allowing enough output tokens for it.

Activation captures and token analyses now save inputs, settings, results and
model identity automatically under `~/.mlx-dyno/research-history/`. Each run gets
its own file. Use saved history to reopen a result, adjust the restored settings,
and run again. Token analyses include returned reasoning text, answers and token
probabilities. Failed captures and analysis errors are retained too. Saved results
can be read without loading a model; a new run still needs the appropriate endpoint.
Previous session-only results cannot be recovered after the old app has quit.
Isolated experiments remain under `~/.mlx-dyno/lab/`; opening their history also
restores the experiment configuration. These are saved results and configurations,
not paused model execution or optimizer checkpoints.

## Install the versioned SDK

The [0.2.0 GitHub release](https://github.com/canivel/mlx-dyno/releases/tag/v0.2.0)
includes a Python wheel, source distribution and checksums alongside the Mac DMG.
Install the downloaded wheel with `python -m pip install mlx_dyno-0.2.0-py3-none-any.whl`.
For a pinned source install including the serving runtime and MCP tools:

```bash
python -m pip install 'mlx-dyno[serve,mcp] @ git+https://github.com/canivel/mlx-dyno.git@v0.2.0'
```

This release is distributed through GitHub; these instructions do not assume a
matching PyPI release. The HTTP API remains `/lab/v1`; the package version is 0.2.0.
The downloadable OpenAPI document includes per-path server URLs for the resident
capture endpoints, which run on your inference server rather than port 8980.
