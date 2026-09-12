# Windows worker telemetry handoff

Implement real GPU telemetry for Dyno Lab's existing paired LAN pool. Preserve unpublished Windows changes. Do not publish a release or replace the Mac checkout wholesale. Return a source ZIP with implementation, tests and a short Mac integration report.

## Current verified state

- One coordinator and one NVIDIA worker have completed GGUF generation together.
- llama.cpp must remain pinned to `5bda51bfbc62e64193221e639f6ad4e08767d760`.
- Native worker SSH uses port **50054**; port 22 may belong to WSL. Preserve the existing host key and dedicated coordinator identity.
- Raw RPC stays **127.0.0.1:50052**, with **GGML_RPC_NO_RDMA=1**.
- The coordinator already recovers legacy port-22 pairings using the original pinned key and HostKeyAlias. Do not ask users to delete known_hosts or disable verification.
- The new Mac dashboard shows local utilization, pool request activity, throughput and backend allocations. Live worker utilization is explicitly unavailable until this telemetry transport exists.

## Implement this transport

1. Start a small read-only HTTP telemetry service at **127.0.0.1:50055** inside the worker application. Start it with the app, so it can report RPC stopped/running/crashed. Do not listen on a LAN or wildcard address. Fail visibly if the port is occupied; do not stop/adopt another process.
2. Expose **GET /v1/telemetry** only. Reject unknown paths and mutations. Set Content-Type application/json and Cache-Control no-store. Bound request headers, concurrent requests and response size (32 KiB maximum). Sampling must happen in a background task, never on the GUI thread or once per HTTP request.
3. Collect a fresh sample about once per second using the existing NVIDIA collector, with a short subprocess timeout. Keep serving a bounded cached response when collection fails; mark metrics unavailable/stale. Do not present cached data as fresh or replace unavailable values with zero.
4. Carry HTTP through a SECOND local forward in the SAME authenticated SSH tunnel as RPC. The coordinator chooses its own free loopback port and forwards it to worker **127.0.0.1:50055**. No new inbound Windows firewall port is necessary. Keep all SSH host checking, identity and route restrictions.
5. Update the worker's explicit local connection setup to permit only these two forwarding targets for this coordinator's existing authorized key:
   `permitopen="127.0.0.1:50052",permitopen="127.0.0.1:50055"`
   Retain source-address restriction, `restrict,port-forwarding`, the forced harmless command, existing key material and unrelated authorized-key entries. Preserve the strict SYSTEM/Administrators ACL. Use the existing elevation/approval flow and provide an **Enable telemetry for paired coordinator** action so an existing pairing can be upgraded without generating a new key or re-pairing. Do not assume the worker owns all SSH configuration.
6. Stop only the telemetry listener owned by this app when the app exits. Stop RPC independently through its existing worker control. A missing or failed telemetry service must not stop inference.

This endpoint is reachable by local worker processes and coordinators explicitly authorized to forward to it. It must not return prompts, model responses, credentials, process command lines, other users' data or arbitrary file contents.

## Response contract

Use `POOL-TELEMETRY-V1.schema.json` beside this document. Required top-level fields:

- `schema_version`: integer 1.
- `instance_id`: random UUID per worker-app launch, allowing the coordinator to detect restarts.
- `sequence`: increasing integer per collection attempt, including failed attempts.
- `sample_age_ms`: age of the most recent collection attempt, computed using the worker's monotonic clock; no requirement to synchronize device clocks.
- `collector_status`: `ok`, `unavailable` or `error`.
- `rpc`: running boolean, process id or null, selected device identifier or null, pinned revision, transport `tcp`, loopback port 50052. Derive running from the owned live process, not from a UI toggle.
- `gpus`: one entry per GPU (bounded to 16), stable GPU id, human-readable name, whether it is selected by the RPC worker, utilization percent, used/total VRAM in bytes, temperature Celsius, power Watts if supported. Unsupported measurements are null, never zero.

GPU values are **device-wide**, not utilization attributable exclusively to Dyno. The selected GPU must be matched to the actual CUDA device/UUID used by RPC; do not silently assume nvidia-smi index equals a remapped CUDA ordinal. Report unknown selection rather than guessing. Document how the Windows build establishes this mapping.

An illustrative response (these numbers are examples, not measured results):

```json
{
  "schema_version": 1,
  "instance_id": "386f70df-80ec-4b0c-b991-839ae87e114e",
  "sequence": 24,
  "sample_age_ms": 130,
  "collector_status": "ok",
  "rpc": {
    "running": true,
    "pid": 1234,
    "device_id": "GPU-example",
    "revision": "5bda51bfbc62e64193221e639f6ad4e08767d760",
    "transport": "tcp",
    "port": 50052
  },
  "gpus": [{
    "id": "GPU-example",
    "name": "NVIDIA GeForce RTX 5090",
    "selected": true,
    "utilization_percent": 72.0,
    "memory_used_bytes": 8589934592,
    "memory_total_bytes": 34359738368,
    "temperature_c": 61.0,
    "power_watts": 210.0
  }]
}
```

## Mac integration to return with the package

The Mac task will extend `runtime.py` with an optional telemetry forward using its existing verified SSH arguments. New saved records must not be required for existing pairings. Failure to read telemetry must show **Unavailable**, not fail the pool or weaken SSH checks. Avoid a repeated failed SSH channel attempt every second when the worker has not enabled forwarding: probe once, back off (for example 30 seconds), and offer Retry telemetry.

The coordinator should poll only its own loopback forward, with no redirects, a 2-second timeout and a 32 KiB limit. Validate types, schema version and finite numeric ranges. A repeated sequence or sample older than 5 seconds becomes **Stale**; an instance change resets the chart. Never fill gaps with zero or combine one worker's samples with another's. Stop polling and close the owned forward when the session stops.

Feed bounded series (for example the last 120 samples) into the existing Mac device cards: utilization chart, used/total VRAM, temperature, optional power, RPC state, last sample age. Keep **device-wide** labeling. Separate physical VRAM totals, live free VRAM, actual model allocations and Metal's process-relative working-set budget. Do not claim that their sum guarantees a model fits.

## Tests and live evidence required on Windows

- Loopback-only listener and occupied-port behavior; unknown routes/methods; size and concurrency bounds.
- Valid schema, null unsupported metrics, nvidia-smi failure/timeout, GPU mapping and no UI blocking.
- Stale samples, increasing sequence on errors, instance id change after restart.
- RPC stopped/running/crashed transitions match the owned process.
- ACL regression and authorized-key upgrade preserve existing key, restrictions and unrelated entries; only two forwarding destinations allowed.
- Port 50055 is not opened in the LAN firewall; existing SSH and RPC listeners unchanged.
- Live compare telemetry utilization/VRAM with nvidia-smi during actual pool generation. Record timestamps and measured values; do not report a pass based solely on idle startup.
- Confirm old coordinators still run inference, and new coordinators gracefully handle a worker without telemetry.

Deliver the changed source, tests, schema, Windows test results and exact build/relaunch instructions. Coordinate with the Mac task for the final tunneled telemetry + inference test.
