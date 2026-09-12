# Python SDK

Automate experiments, read results and download artifacts with `dyno.sdk`. For the Mac interface, start with the [app handbook](app-guide.md). For request schemas and curl examples, use the [HTTP API reference](http-api.md).

The SDK has two clients: **ServingModel** captures an already-loaded model; **Lab** creates persistent experiments in a separate worker. They have different memory costs and return types.

## Install

Create a Python 3.10+ environment. Download the Python wheel from the [0.2.2 release assets](https://github.com/canivel/dynolab/releases/tag/v0.2.2), then install it:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install ./mlx_dyno-0.2.2-py3-none-any.whl
python -c 'from dyno.sdk import Lab, ServingModel; print("SDK ready")'
```

On Windows, activate with `.venv\Scripts\activate`; in WSL, use the Bash command above. The research services accept only loopback requests, so run these research examples on the Mac hosting Dyno. Remote computers can use the [inference API](http-api.md#inference-and-lan-clients).

The client uses Python's standard library. Installing the client alone does not install the MLX inference runtime. For a source installation that can also serve models, run this on an Apple Silicon Mac:

```bash
python -m pip install 'mlx-dyno[serve,mcp] @ git+https://github.com/canivel/dynolab.git@v0.2.2'
```

The repository is named `dynolab`, the distribution remains `mlx-dyno`, and the import namespace is `dyno`. These instructions use the GitHub release rather than assuming a matching PyPI release. The Mac DMG bundles the server runtime; you can use it without installing a second serving environment.

## Choose a client

| Client | Service | Returns | Use it for |
|---|---|---|---|
| `ServingModel(port=8971, timeout=75)` | Running Dyno inference endpoint | A result dictionary directly | Activation norms and final next-token candidates, reusing loaded weights |
| `Lab(base_url="http://127.0.0.1:8980", timeout=10)` | Lab service started in the app or with `dyno lab` | Job metadata, then a completed job containing `result` | Full activation artifacts, interventions, probes and SAE experiments |

`timeout` is the HTTP request timeout in seconds. `Lab.wait()` has its own overall polling deadline. Supply the origin as `base_url`, without `/lab/v1`; the client adds that prefix.

## First capture: reuse your running model

Start a model in **Models** using a current Dyno version. Use its inference port below. No separate Lab service is required.

```python
from dyno.sdk import ServingModel

server = ServingModel(port=8971)
capabilities = server.capabilities()
print(capabilities)

result = server.inspect(
    "The capital of France is",
    layers=[4, 8],
    max_input_tokens=128,
)
for candidate in result["next_tokens"]:
    print(repr(candidate["token"]), candidate["probability"])
for layer in result["layers"]:
    print(layer["layer"], layer["norms"])
```

Choose valid layer indices for your model. `inspect()` looks up the exact resident model identity before submitting, so it cannot silently load a different model. Capture permits one to four distinct layers and at most 256 input tokens; omitted `layers` defaults to `[0]`. It uses raw text, not a chat template, and does not need Thinking enabled.

The result contains `tokens`, `token_ids`, `layers`, `next_tokens` and provenance. Norms are magnitudes, not attention or importance. This mode has no raw tensor artifacts or intermediate logit lens. It uses temporary workspace and shares serving GPU time; it may delay requests even though it does not duplicate weights.

SDK calls do not automatically add results to the native app's saved-capture history. Save your direct result explicitly:

```python
import json
from pathlib import Path

Path("capture.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
```

## First isolated experiment

Open **Lab → Experiments → Start lab**, or run `dyno lab --port 8980` in your serving environment. Allow memory for another model copy and run when the GPU is quiet. The native app's resource admission checks are not applied to SDK submissions.

```python
from dyno.sdk import Lab

lab = Lab()
print(lab.health())
model = "mlx-community/Qwen1.5-0.5B-Chat-4bit"
job = lab.inspect(
    model=model,
    prompt="The capital of France is",
    layers=[4, 8],
    max_input_tokens=128,
    seed=0,
)
print("Job:", job["id"])
completed = lab.wait(job["id"], timeout=300)
print(completed["result"]["next_tokens"])
path = lab.artifact(job["id"], "activations.npz", "activations.npz")
print("Saved:", path)
```

The service may download a model ID if needed. A local directory uses existing weights; an optional `revision` pins a Hugging Face revision. Pin an actual revision for reproducible studies. The service stores configuration, logs, results and artifacts under `~/.mlx-dyno/lab/<id>`.

Inspect artifacts contain arrays named `layer_4`, `layer_8`, etc. Array axes are batch, input token and hidden dimension. Reading NPZ files requires NumPy or MLX, separately from the lightweight SDK.

## Compare interventions

This experiment scales the final-token output of layer 8 and compares next-token probabilities at the identical prompt prefix. It also records separate greedy continuations.

```python
from dyno.sdk import Lab

lab = Lab()
job = lab.compare(
    model="mlx-community/Qwen1.5-0.5B-Chat-4bit",
    prompt="The capital of France is",
    layers=[8],
    intervention="scale",
    strengths=[0, 1, 1.5],
    max_tokens=12,
    seed=0,
)
result = lab.wait(job["id"])["result"]
for trial in result["trials"]:
    print(trial)
```

Scaling strength 1 is the neutral control. Free-running continuations can diverge; compare target-token probabilities before interpreting differences in later text. See [experiment parameters](http-api.md#experiment-parameters) for `ablate`, `patch`, `steer`, `target_token` and multi-prompt comparisons.

## Train a probe or SAE

The following toy dataset demonstrates the format. It is too small to establish useful generalization or validate a safety detector. Keep both binary classes in both splits for probes; use unseen test examples and check for leakage.

```python
from dyno.sdk import Lab

lab = Lab()
model = "mlx-community/Qwen1.5-0.5B-Chat-4bit"
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
probe = lab.probe(model, examples, layers=[8], seed=0)
print(lab.wait(probe["id"])["result"]["reports"])

# Wait for the probe before submitting: only one isolated job runs at once.
sae = lab.sae(model, examples, layers=[8], features=16, steps=20, seed=0)
completed = lab.wait(sae["id"])
print(completed["result"]["reports"])
print(completed["result"]["artifacts"])
```

Probes report held-out accuracy, AUROC, Brier score and controls. Their weights and normalization are fitted only to training data. A probe shows decodability, not causal use of a concept.

SAEs train a small ReLU/L1 autoencoder on final-token states. Examine held-out reconstruction error together with active/dead feature statistics. Numbered features have no validated semantic labels. Pretrained SAE import and steering with learned SAE features are not supported in this release.

## Method reference

| Method | Arguments | Return / behavior |
|---|---|---|
| `Lab.health()` | None | Service capabilities |
| `Lab.schema()` | None | OpenAPI dictionary |
| `Lab.jobs()` | None | List of up to 100 recent job summaries, newest first |
| `Lab.submit(operation, model, **settings)` | `inspect`, `compare`, `probe` or `sae`; model ID/path; configuration | Submitted job dictionary including `id` |
| `Lab.inspect(model, prompt, **settings)` | Raw prompt and inspect settings | Shortcut for `submit("inspect", ...)` |
| `Lab.compare(model, prompt, **settings)` | Raw prompt and intervention settings | Shortcut for `submit("compare", ...)` |
| `Lab.probe(model, examples, **settings)` | Labeled train/test examples | Shortcut for `submit("probe", ...)` |
| `Lab.sae(model, examples, **settings)` | Train/test texts and training settings | Shortcut for `submit("sae", ...)` |
| `Lab.job(identifier)` | Job ID | Full configuration, status, error/result |
| `Lab.wait(identifier, timeout=1800, interval=0.5)` | Overall deadline and polling interval in seconds | Completed job, or exception |
| `Lab.cancel(identifier)` | Job ID | Job metadata; stops that isolated worker only |
| `Lab.artifact(identifier, name, destination)` | Name listed in `result.artifacts`; local output path | Downloaded `pathlib.Path`; overwrites that destination |
| `ServingModel.capabilities()` | None | Resident model identity, capture support and limits |
| `ServingModel.inspect(prompt, layers=None, max_input_tokens=128)` | Raw text and valid layer indices | Direct measurements, not a job |

There is no SDK delete method; use HTTP `DELETE /lab/v1/jobs/{id}` for a terminal job. `Lab.jobs()` does not list native saved token analyses or direct resident captures.

## Errors, cancellation and resuming work

```python
from dyno.sdk import Lab, DynoError
from urllib.error import URLError

lab = Lab()
identifier = "PASTE_YOUR_JOB_ID"
try:
    completed = lab.wait(identifier, timeout=60)
except TimeoutError:
    print("Still running; poll this ID later, or cancel explicitly.")
except DynoError as error:
    print("Job/API error:", error)
except (URLError, OSError) as error:
    print("Check the Lab service and port:", error)
```

HTTP errors from JSON requests become `DynoError`; failed, cancelled or interrupted jobs also cause `wait()` to raise it. Network failures and artifact-download errors can retain their underlying urllib exceptions. A wait timeout **does not cancel the job**. Call `lab.cancel(identifier)` when you intend to stop it, then inspect `lab.job(identifier)`.

To continue a study after restarting your script, keep the job ID and call `lab.job(id)` or `lab.wait(id)` again. To rerun its configuration, use `lab.submit(**saved_job["config"])`. This creates a new job; it does not resume optimizer state. If the Lab service itself was interrupted, previously active jobs are marked interrupted on startup.

## Research interoperability

Version 0.2.2 exposes `Lab.patch_sweep` and the data-only `dyno.interop` exporters for external attention, SAELens feature activations and Circuit Tracer subgraphs. See [research tools](https://github.com/canivel/dynolab/blob/main/docs/research-tools.md) for examples. These adapters do not install or run the upstream model backends.

## Using a GPU pool

For pool inference, use the [Pool API Python example](pool-api.md#python-without-extra-dependencies). `Lab` and `ServingModel` target research services and do not control or inspect distributed GGUF pools. See the [pool setup guide](pool-guide.md) for the development preview.

## Pool research

Use Lab.submit_pool(operation, resident_model_path, pool_port=8978, **settings) for a running GGUF pool with research runtime v2. The Lab client URL stays on the research service. Jobs, cancellation and artifact downloads use the existing SDK methods. See [pool research](pool-lab-capture.md) for limits and examples.

## Worked example: reference corruption

The [Qwen3.8 identifier-fidelity experiment](https://dynolab.dev/probe-example.html) includes importable Lab JSON, exact prompts, generated outputs, saved weights, SDK submission and HTTP commands. It uses the existing jobs and artifacts APIs. The probe predicts literal reference absence, not harmfulness or deceptive intent.
