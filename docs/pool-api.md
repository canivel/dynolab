# Pool API and Python clients

**Development preview.** Start a pool using the [setup guide](pool-guide.md). Pool inference uses the pinned llama.cpp server, not Dyno's MLX research server. The default base URL is `http://127.0.0.1:8978/v1`; use the port and alias shown by your pool.

## Inference endpoint

Run these on the coordinator. The pool endpoint is loopback-only in this preview.

```bash
curl --fail http://127.0.0.1:8978/health
curl --fail http://127.0.0.1:8978/v1/models
curl --fail http://127.0.0.1:8978/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dyno-pool","prompt":"The capital of France is","max_tokens":32,"temperature":0,"stream":false}'
```

The tested raw completion path returns generated text in `choices[0].text`. Record `usage` and backend `timings` when present; do not assume every OpenAI-compatible endpoint provides identical timing fields. Raw prompts do not apply a chat template or Dyno's MLX Thinking setting. Chat behavior depends on the chosen GGUF and backend template and requires its own validation.

`/health` readiness does not establish placement across both GPUs. Combine inference output with the pool supervisor's allocation logs and worker telemetry for acceptance evidence.

## Python without extra dependencies

```python
import json
import urllib.request

base = "http://127.0.0.1:8978/v1"
request = urllib.request.Request(
    base + "/completions",
    data=json.dumps({
        "model": "dyno-pool",
        "prompt": "The capital of France is",
        "max_tokens": 32,
        "temperature": 0,
    }).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=120) as response:
    result = json.load(response)
print(result["choices"][0]["text"])
```

## SDK compatibility

An OpenAI-compatible inference client may target the pool's `/v1` base URL and configured model alias. The standard-library example above is the minimal tested request shape.

`dyno.sdk.Lab` and `dyno.sdk.ServingModel` are research clients. They do not implement pool lifecycle control and must not be pointed at the pool as though it were an MLX research endpoint. The research OpenAPI document describes research contracts, not this upstream inference server.

There is currently no public pool-management REST API or MCP pool tool. Use the native Pools UI or the development CLI. Do not invent `/pools/start`, `/lab` or worker-management HTTP routes.

## Lifecycle CLI

Install pool dependencies in a development environment with `python -m pip install '.[pool]'`. A matching backend binary is also required.

```bash
dyno pool interfaces
dyno pool plan --config pool.json
dyno pool probe --config pool.json --experimental
dyno pool start --config pool.json --experimental
```

The start command remains in the foreground; Ctrl-C stops its owned coordinator/tunnel. The worker app owns its RPC service separately. The standalone pairing preview is `dyno pool pair` and requires Tk; the native UI does not.

Use a configuration saved by the app. It includes `binary`, `model`, `local_address`, `peer`, `user`, `ssh_port`, `rpc_port`, `port`, `context`, `alias`, and `pairing_id`. The pairing ID refers to private local identity/host-key files and is not portable to another coordinator. Do not commit saved configurations or credentials.

## Telemetry contract

The worker's loopback HTTP service exposes `GET /v1/telemetry` on port 50055. The coordinator reaches it through the verified SSH tunnel. It is an internal read-only operational interface, not the inference endpoint or a LAN-facing browser API.

Schema version 1 includes instance/sequence/freshness metadata, collector status, RPC running/device information and GPU utilization, used/total VRAM, temperature and optional power. The selected GPU is matched by UUID. Samples older than five seconds or repeated/regressing sequence numbers are stale. Missing telemetry does not stop inference.

See the [worker repository](https://github.com/canivel/dynolab-windows-client) and [versioned schema](https://github.com/canivel/dynolab/blob/main/docs/handoffs/POOL-TELEMETRY-V1.schema.json) for the protocol. Poll through the coordinator; do not expose ports 50052 or 50055 on the LAN.

## Development Lab capture

The development runtime supports bounded pooled activation norms. See [pool Lab capture](pool-lab-capture.md) for setup, API limits and validation. Research runtime v2 adds pooled interventions/causal patching and probe/SAE training from captured vectors.

### Loading large models

`load_timeout_seconds` sets the maximum loading time (integer 60–7200; default 600). A large worker shard can take longer than ten minutes to transfer over Wi-Fi. Inspect actual transfer progress before increasing the limit; a longer deadline does not establish that a model fits. The native app stores private per-run diagnostics in `~/.mlx-dyno/pool-logs/`. Keep these logs out of public commits.

Metal `_Mapped` model-buffer values describe mapped address ranges, not resident RAM. They can include gaps between tensors. Do not add them to worker VRAM usage or treat them as measured physical allocation.
