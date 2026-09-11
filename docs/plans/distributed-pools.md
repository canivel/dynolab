# Dyno distributed model pools — proposed plan

Status: proposal only, 11 September 2026. No backend installation, server changes or deployment performed.

## Product decision

Add a distributed execution mode alongside standalone serving. Keep the router responsible for routing whole requests; represent a running distributed pool as one backend with a stable model alias. A pool distributes one model's computation and memory across approved devices. It is not transparent unified VRAM, and combining devices does not guarantee faster generation.

The quoted “MMX” reference has not been identified. For the Mac backend evaluate official MLX/MLX-LM distributed inference directly; do not add an unidentified dependency.

## Backend selection

- Mixed macOS/Windows/Linux: prototype one pinned llama.cpp version using GGUF and its ggml RPC backend. Official documentation demonstrates remote CUDA and Metal devices, memory-based distribution and configurable split proportions. Validate each OS/accelerator/model combination; generic backend support is not a tested product matrix.
- Mac clusters: a separate MLX/MLX-LM adapter, with TCP ring or JACCL where hardware and OS support it. Evaluate pipeline versus tensor sharding for each supported model.
- Current MLX docs also describe CUDA/NCCL. This does not establish interoperable mixed Metal/CUDA ranks or native Windows support; investigate separately rather than promising it.
- Do not combine resident MLX allocations and GGUF RPC allocations in the same execution graph. Selecting a different engine requires its own compatible model artifact and memory allocation.

## Architecture

Mac app -> pool control service -> paired node agents -> isolated runtime processes.
Clients -> existing Dyno router -> pool coordinator's OpenAI-compatible endpoint -> backend-managed remote compute.

The coordinator is a runtime process and may run on an approved Windows/Linux GPU machine while the Mac remains the management UI. Benchmark both coordinator placements. Each pool owns its runtime processes; existing user servers stay outside that ownership boundary.

Proposed code areas:

- `src/dyno/pool/`: models, persistent registry, lifecycle service, resource leases, planner and adapters (`llama_rpc`, later `mlx_distributed`).
- `src/dyno/node/`: cross-platform agent, enrollment, heartbeat, inventory and constrained process supervisor. Keep macOS telemetry imports out of portable modules.
- `src/dyno/router/backends.py`: pool identity, authenticated endpoint registration and capabilities. Replace current simplistic URL parsing; do not strip HTTPS. Model alias must resolve to the requested pool, never a silently substituted model.
- `app/Sources/DynoKit/PoolClient.swift` and `PoolController.swift`: native state and lifecycle.
- `app/Sources/Dyno/Views/PoolsView.swift`: membership, planning, start/drain/stop and diagnostics. Models displays pool-backed models.
- Extend SDK, OpenAPI and MCP with explicit pool operations and capabilities.

## UI flow

1. **Pools -> Add computer.** Run a signed companion agent on the other machine, pair with a short-lived code and verify its identity. Manual address entry plus optional discovery. Discovery is not authorization.
2. **Choose devices and network.** Show OS, backend version, accelerator, free memory, existing reservations and active requests. Explicit wired/Wi-Fi/interface selection on multihomed hosts; measure the selected route. Treat WSL as its own runtime/network environment.
3. **Choose model and goal.** Verify artifact digest, architecture, tokenizer/template and quantization. Goals: fit a larger model, minimize latency, or maximize throughput. Offer independent replicas when that better serves throughput.
4. **Preview allocation.** Show per-node weight allocation, KV cache/context and concurrency budget, workspace, safety reserve, staging/cache storage and estimated performance confidence. No fabricated tokens/sec before measurement.
5. **Start pool.** Reserve capacity on every node, stage/load and warm up, then register a healthy endpoint. Failed partial startup releases all owned resources.
6. **Monitor.** Time to first token, prefill/decode rates, latency distribution, selected links, transfer volume, GPU utilization, available memory, queue and node state. Separate coordinator measurements from per-node measurements.
7. **Drain or stop.** Drain stops new requests and lets current ones finish. Force stop clearly reports interruption. Node loss fails affected streams explicitly; no seamless failover or continuation claims.

## Placement and memory planning

Profile each candidate node with representative model operations or a calibration load and measure links between relevant peers, including through the actual secure transport. GPU model names alone do not determine placement. In sequential layer execution, stage times add; balancing device speeds is not automatically optimal. Tensor parallelism introduces collective synchronization and can be much more network-sensitive.

Start with backend-supported layer splitting and explicit split proportions, inspect actual placement, then benchmark small candidate plans. More layers on a fast GPU is a hypothesis, constrained by memory, transfer overhead and architecture. Respect shared memory bandwidth and thermal/power contention as well as allocation limits.

Budget weights + context-dependent KV cache + scratch buffers + backend duplication + reserve independently for each node. Aggregate memory is a display total, not a promise that any model fits. Resident single-node weights are not automatically reusable. No silent eviction or stopping of existing endpoints. An agent lease avoids Dyno overbooking; external processes can still change capacity, requiring revalidation.

## Security and distribution

Upstream calls RPC proof-of-concept, fragile and insecure. Therefore the first version is a trusted-device research preview, not a secure multi-tenant service. Do not expose raw RPC to arbitrary LAN clients or the internet. Bind it to loopback behind authenticated encrypted tunnels, with device allowlists and revocable pairing. Encryption does not repair parser vulnerabilities or make malicious enrolled workers safe.

Node agents run as ordinary users, launch only approved pinned runtimes/configurations, enforce resource limits and never expose a generic shell execution API. Separate management credentials from inference API credentials. Joining a pool authorizes that worker to handle model data and activations; document that trust boundary. Pin compatible versions across workers and coordinator, verify downloads/checksums, and provide platform-specific installers. Do not assume the Mac DMG can distribute working CUDA binaries to Windows/Linux.

## Lab integration

Initial capabilities: inference/chat, execution metadata and token analysis only where backend logprobs are verified. Advertise capabilities per pool. Existing MLX activation taps, interventions, probes and SAE training do not work on RPC merely because chat does.

Later define a distributed capture protocol with exact model/artifact digest, global layer IDs, tensor layout, node assignment, backend revision and reproducible configuration. Begin with bounded read-only capture. Add intervention controls only after no-op parity, cleanup and isolation tests; keep them in dedicated research pools. Persist topology and runtime metadata with every study.

## Phases and exit gates

### 1. Hardware feasibility spike

Two machines: Mac Metal plus NVIDIA Windows or Linux, same pinned llama.cpp build and small supported dense GGUF. Benchmark local baselines, each coordinator placement and actual cross-machine allocations. Then try a model that exceeds either chosen GPU budget individually. Check cold/warm load, short/long prompts, decode and concurrency. Compare output/logit tolerances, not bitwise floating-point identity. Gate: both devices demonstrably participate, explicit overhead measurements, stable streaming, disconnect/cancel recovery and no unexplained memory growth.

### 2. Experimental Pools MVP

Paired agent, fixed membership, manual allocation plus measured suggestions, secure transport, stable endpoint, stop/drain and saved configurations. Test Mac+Cuda Linux, Mac+native Windows CUDA and Mac+WSL separately before claiming support. Fault tests: OOM during startup, stale leases, lost worker, coordinator restart, version mismatch, wrong model digest, unauthorized peer and route failure. Gate: repeatable two-node setup and no impact on unrelated serving processes.

### 3. Planner and operational reliability

Measured placement search; automatic recommendation of one node versus pooling versus replicas. Admission control for context/concurrency, memory pressure alerts, cached model staging, upgrades, capability registry and larger topologies. Gates: improves the chosen goal against a measured baseline or clearly explains why pooling is useful only for capacity. No live topology changes in an active generation.

### 4. Native MLX pools

Mac-specific adapter using the same node/control/lifecycle abstraction, gated by model sharding support and link topology. Capability-check TCP/JACCL prerequisites; do not alter system RDMA/security settings automatically.

### 5. Distributed interpretability

Reproducible captures, selected interventions and saved evidence with topology provenance. Gate each capability independently against single-node controls; backend support may remain unequal.

## Proposed management contract (not implemented)

Authenticated management endpoints: `GET /pool/v1/nodes`, `POST /pool/v1/plans`, `POST /pool/v1/pools`, `POST /pool/v1/pools/{id}/start`, `/drain`, `/stop`, and `GET /pool/v1/pools/{id}/events`.

Plans include a revision and expiry. Start validates the plan against current inventory before allocating. SDK methods mirror these operations; MCP provides separate read/plan/start/stop tools. Inference keeps `/v1/chat/completions` and a stable pool model alias.

## Sources checked

- llama.cpp RPC architecture, splitting, cache, security warning and RDMA: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- Platform accelerator builds: https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
- MLX communication backends, including ring, JACCL and NCCL: https://ml-explore.github.io/mlx/build/html/usage/distributed.html
- MLX launching and interface configuration: https://ml-explore.github.io/mlx/build/html/usage/launching_distributed.html
- Apple distributed MLX overview and parallelism: https://developer.apple.com/videos/play/wwdc2026/233/

All backend claims require pinning and validating the selected release. This plan is grounded in source inspection, not a completed multi-machine benchmark.
