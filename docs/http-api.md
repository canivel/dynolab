# HTTP API

Dyno exposes inference, persistent research jobs, resident activation capture and an execution inspector. Choose the correct service before sending a request. The native app does not need these calls for normal use; see the [app handbook](app-guide.md). Python users can use the [SDK](sdk-guide.md).

## Services and access

| Service | Typical origin / prefix | Start it with | Network access |
|---|---|---|---|
| Model inference | `http://127.0.0.1:8971/v1` | Models → Start, or `dyno serve` | Depends on server binding |
| Routed inference | `http://127.0.0.1:8970/v1` | Router → Start the router | LAN when explicitly enabled |
| Isolated research | `http://127.0.0.1:8980/lab/v1` | Lab → Start lab, or `dyno lab` | Loopback only |
| Resident activations | `http://127.0.0.1:8971/lab` | Current Dyno inference server | Loopback only |
| Execution inspector | Inference server `/executions` | Current Dyno inference server | Loopback only |

Ports are examples; use the values configured on your Mac. Research and execution endpoints reject LAN and browser-origin requests even if inference is shared. They are intended for native clients, curl, Python and the local MCP bridge. LAN inference has no built-in authentication; use a trusted network.

The [downloadable OpenAPI 3 document](https://dynolab.dev/openapi.json) describes the research job and resident-capture contracts. Its resident paths override the default server URL. It is not a full specification of inference or the execution inspector.

## Inference and LAN clients

Start a model, then list the served identifiers:

```bash
curl http://127.0.0.1:8971/v1/models
```

Use the returned model identifier in `model`. For the router use model `auto`. This Bash example prompts for the URL and model so it works with your local configuration:

```bash
read -r -p 'Base URL (including /v1): ' DYNO_BASE_URL
read -r -p 'Model identifier (auto for router): ' DYNO_MODEL
export DYNO_MODEL
python3 - <<'PY' > request.json
import json, os
print(json.dumps({
    "model": os.environ["DYNO_MODEL"],
    "messages": [{"role": "user", "content": "Explain why leaves are green."}],
    "max_tokens": 120,
    "temperature": 0,
    "stream": False,
    "chat_template_kwargs": {"enable_thinking": False}
}))
PY
curl "$DYNO_BASE_URL/chat/completions" \
  -H 'Content-Type: application/json' --data-binary @request.json
```

For Windows/WSL or another computer, enable **Router → Share on local network** and enter the copied client URL. `127.0.0.1` on Windows points to Windows, not the Mac. Test reachability before debugging payloads. Do not use a screenshot's private IP address.

Read the answer from `choices[0].message.content`. Compatible models may return `reasoning_content` separately. `chat_template_kwargs.enable_thinking` overrides the launch default only when the model's template supports it. Raw-text research requests do not use this setting.

For streamed responses set `stream: true` and use `curl -N`. Read SSE `data:` events until `[DONE]`; accumulate text deltas rather than expecting one final JSON document. To request token probabilities, set `logprobs: true` and `top_logprobs: 5` on a supporting direct model endpoint. Log probabilities are in `choices[0].logprobs.content`; convert with `exp(logprob)`.

## Isolated research: first request

Start **Lab → Experiments → Start lab**. A source installation can use `dyno lab --port 8980`. Check health, then submit:

```bash
curl http://127.0.0.1:8980/lab/v1/health
curl http://127.0.0.1:8980/lab/v1/jobs \
  -H 'Content-Type: application/json' \
  -d '{"operation":"inspect","model":"mlx-community/Qwen1.5-0.5B-Chat-4bit","prompt":"The capital of France is","layers":[4,8],"max_input_tokens":128,"seed":0}'
```

Successful submission returns **202** with job metadata including `id`, `status`, `operation`, `model` and `config`. Submission is not completion. Copy the returned ID, then poll:

```bash
read -r -p 'Job ID: ' DYNO_JOB_ID
curl "http://127.0.0.1:8980/lab/v1/jobs/$DYNO_JOB_ID"
```

When `status` is `completed`, inspect `result`. Inspect results include token strings/IDs, layer norms, final `next_tokens`, available intermediate predictions, provenance and artifact names. If `status` is `failed`, read `error`; invalid architecture or operation-specific inputs can fail in the worker after a successful 202 submission.

Each job loads its own model copy. Only one isolated job runs at a time. SDK/HTTP clients do not receive the native app's memory/GPU admission checks. Check headroom and competing serving activity before submission. A model ID may download weights; a local model directory uses an existing download.

## Job endpoints

All paths below use `http://127.0.0.1:8980` unless you configured a different Lab port.

| Method | Path | Success | Response |
|---|---|---|---|
| GET | `/lab/v1/health` | 200 | Service capabilities |
| GET | `/lab/v1/openapi.json` | 200 | Research OpenAPI document |
| POST | `/lab/v1/jobs` | 202 | Submitted job metadata |
| GET | `/lab/v1/jobs` | 200 | `{ "jobs": [...] }`, newest 100 summaries |
| GET | `/lab/v1/jobs/{id}` | 200 | Full job with configuration and result/error |
| POST | `/lab/v1/jobs/{id}/cancel` | 200 | Job metadata; send JSON `{}` |
| DELETE | `/lab/v1/jobs/{id}` | 200 | `{ "deleted": true }`; terminal jobs only |
| GET | `/lab/v1/jobs/{id}/artifacts/{name}` | 200 | Binary file listed by the job |

Jobs progress from `queued` to `running` to `completed`, `failed` or `cancelled`. If a service restarts with an unfinished job on disk, that job is marked `interrupted`. Saved jobs persist under `~/.mlx-dyno/lab/<id>`. Native token-analysis history and direct resident captures are separate and do not appear here.

Download, cancel or delete deliberately:

```bash
curl --fail "http://127.0.0.1:8980/lab/v1/jobs/$DYNO_JOB_ID/artifacts/activations.npz" -o activations.npz
# Stop the isolated worker, if it is still running:
curl "http://127.0.0.1:8980/lab/v1/jobs/$DYNO_JOB_ID/cancel" \
  -H 'Content-Type: application/json' -d '{}'
# Delete the terminal job and its artifacts:
curl -X DELETE "http://127.0.0.1:8980/lab/v1/jobs/$DYNO_JOB_ID"
```

Cancellation does not stop an inference server. Deleting a running job returns 409; cancel it first. Downloaded files are not deleted by deleting their server-side job.

## Experiment parameters

Common fields for `POST /lab/v1/jobs`:

| Field | Default / allowed values | Meaning |
|---|---|---|
| `operation` | Required: `inspect`, `compare`, `probe`, `sae` | Experiment type |
| `model` | Required nonempty string | Hugging Face ID or local model directory |
| `revision` | Optional revision string | Pin a model revision |
| `layers` | `[0]`; 1–8 indices, each 0–255 | Zero-indexed block outputs; indices must exist in the model |
| `prompt` | Required in practice for inspect/compare | Raw text, without chat template |
| `max_input_tokens` | 256; range 1–1024 | Input token limit |
| `max_tokens` | 32; range 1–128 | Greedy continuation budget for comparisons |
| `seed` | 0; range 0–2147483647 | Experiment seed |
| `examples` | At most 512 entries | Explicit training/test dataset for probe or SAE |

The request body is limited to 500,000 bytes. Workers have a 30-minute deadline. Compatibility requires supported MLX block layouts; downloading an MLX model does not guarantee that every research operation supports it.

### Interventions (`compare`)

Use one selected layer: the worker intervenes at the first selected layer. The intervention changes the block's last-token output on every forward pass.

| Field | Values / behavior |
|---|---|
| `intervention` | `scale` (default), `ablate`, `patch`, `steer` |
| `strengths` | 1–9 finite numbers between −5 and 5; default `[0,0.5,1,1.5]` |
| `target_token` | Optional text encoding to exactly one token; otherwise baseline's top token |
| `prompts` | Optional 1–32 prompts for repeated comparisons; still provide `prompt` |
| `donor_prompt` | Donor text for patching |
| `positive`, `negative` | Two texts whose final-token activation difference supplies a unit steering direction |

Scale strength 1 leaves the state unchanged. Ablation, patch and steering strength 0 leave it unchanged. Target-token probabilities are compared at the identical input prefix. Greedy continuations can diverge and are not aligned causal traces of later tokens.

```json
{
  "operation": "compare",
  "model": "mlx-community/Qwen1.5-0.5B-Chat-4bit",
  "prompt": "The capital of France is",
  "layers": [8],
  "intervention": "scale",
  "strengths": [0, 1, 1.5],
  "max_tokens": 12,
  "seed": 0
}
```

### Probes (`probe`)

Each example needs `text`, binary `label` (0 or 1) and `split` (`train` or `test`). Both classes must occur in each split; exact cross-split duplicate texts are rejected. The [SDK dataset example](sdk-guide.md#train-a-probe-or-sae) supplies a complete minimal demonstration.

Features are final-token block activations, standardized using training statistics. Regularized logistic probes report held-out accuracy, AUROC, Brier score, majority baseline and shuffled-label control. Artifact weights are evaluated as `sigmoid(((x - mean) / std) @ weight + bias)`. Good probe accuracy shows decodable information, not necessarily a representation the model causally uses.

### SAE sandbox (`sae`)

Examples need `text` and explicit `split`; labels are not required. Supply training and held-out examples. `features` defaults to 64 (range 8–512); `steps` defaults to 100 (range 1–500). It trains a small ReLU encoder/linear decoder with L1 regularization on final-token activations.

Results include reports with held-out reconstruction MSE, active/dead feature statistics, training losses and top activating examples. Artifacts include weights and normalization. Feature indices are not validated concepts. Importing pretrained SAEs and steering with their decoder features are not implemented.

## Resident activation endpoints

These run on the inference port, not the Lab job port. First discover support:

```bash
curl http://127.0.0.1:8971/lab/capabilities
```

Read `serving_activations` and copy the exact returned `model`. An updated Dyno endpoint enables this automatically; an old process must be restarted explicitly. Then submit JSON with:

```json
{
  "model": "COPY_EXACT_CAPABILITIES_MODEL_VALUE",
  "prompt": "The capital of France is",
  "layers": [4, 8],
  "max_input_tokens": 128
}
```

Save that payload as `capture.json`, then run:

```bash
curl --max-time 75 http://127.0.0.1:8971/lab/activations \
  -H 'Content-Type: application/json' --data-binary @capture.json
```

| Method | Path | Behavior |
|---|---|---|
| GET | `/lab/capabilities` | Model identity, support and limits |
| POST | `/lab/activations` | Direct measurement result (200), not a job ID |

Allowed fields are `model`, `prompt`, `layers` and `max_input_tokens`; unknown fields are rejected. Use 1–4 distinct layers and at most 256 input tokens (default 128). A model mismatch fails rather than loading new weights. The result supplies tokens, layer norms, final next-token candidates and provenance; no raw tensor artifact or intermediate logit lens.

Only one capture can be pending/running. It runs on the generation thread between scheduler iterations using fresh forward-pass state. It shares GPU/workspace and may briefly delay requests. A queued capture expires after 60 seconds; a forward pass already started completes before serving resumes. Client timeout is not a cancellation API.

## Execution and performance endpoints

On a current inference server, `GET /stats` exposes instrumented serving metrics. The native Performance view combines these with Mac hardware telemetry. An arbitrary OpenAI-compatible server may not support this extension.

The execution inspector uses:

| Method | Path | Purpose |
|---|---|---|
| GET | `/executions` | Recent captured request summaries and capture counters |
| GET | `/executions/{id}` | Request, lifecycle events and model output for a trace |
| DELETE | `/executions` | Clear finished traces; active requests keep running |

Execution is bounded, in-memory history, not the persistent research job store. It captures at most 64 requests per endpoint with content/step limits. Model-emitted reasoning is returned text, not complete access to internal computations. A skipped-history count concerns capture capacity; it does not mean inference failed. These endpoints reject LAN and browser-origin access.

## Errors and troubleshooting

Research JSON errors have an `error` message. Inspect the HTTP status and, for accepted jobs, the eventual job status.

| Status / condition | Meaning | Next step |
|---|---|---|
| 400 | Invalid JSON, body size or parameters | Check field types, limits and required model/prompt |
| 403 | Research/Execution request blocked by local-access rules | Use a native loopback client on the serving Mac |
| 404 | Job, artifact or route absent | Verify service port, prefix, ID and listed artifact name |
| 408 (resident) | Queued capture expired | Wait for serving capacity and retry |
| 409 | Job/capture busy, model conflict, or deletion of active job | Read the message; wait, correct identity, or cancel deliberately |
| Connection refused | Service not started or wrong port | Start the intended service and use its configured port |
| Job `failed` after 202 | Worker rejected data or model execution failed | Read `error`; check architecture, layer indices and dataset |

Results include provenance such as configuration hash, runtime versions, requested revision and resolved model information. A weight-file size/time manifest is not a cryptographic checksum of weights. Keep the configuration, artifact files and exact model revision when sharing an experiment.

## Causal patching

`POST /lab/v1/jobs` additionally accepts `operation: "patch_sweep"`, `prompt` (corrupted), `clean_prompt`, distinct single-token `target_token` and `foil_token`, `layers`, and optional `positions`. Prompts must have equal token counts; at most 128 layer/position pairs are tested. Results include `patches`, clean/corrupted logit differences and a restored control. SAE jobs accept `sae_architecture: "relu"` or `"topk"`, with `top_k` between 1 and `features`.

## GPU pool inference (development preview)

Pools use a separate loopback llama.cpp endpoint, normally `http://127.0.0.1:8978/v1`. See the [Pool API](pool-api.md) for raw completions, Python examples, lifecycle CLI and telemetry. The research OpenAPI schema does not describe this endpoint.
