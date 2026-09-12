# Mac coordinator pairing integration — development validation

September 11, 2026. No release was published and no existing checkout was replaced.

## Imported Windows source

Read `worker/windows/PAIRING.md` and `WINDOWS-TEST-RESULTS.md` from the supplied discovery archive before merging. Imported only relevant pool modules, worker scripts/tests and optional dependencies. Existing CLI, native UI, CI and other unpublished changes were retained. Copies of overwritten local files were preserved outside the checkout before merging.

The Windows report records 24 passing Python tests and an ACL test, a successful discovery-package build, and Application Control blocking that package's launch. Its earlier GUI/runtime pass applies to the older worker package only. It does not establish cross-machine pairing or inference.

## Native integration

- Selected-network discovery and Nearby workers are part of Pools.
- Both-device confirmation displays the entire eight-group verification code. No trust is accepted from an advertisement.
- Dedicated SSH identities/host-key files and multiple saved connections are supported. Selection merges only connection fields, preserving the model and runtime settings.
- Plan, Test devices and Start pool enforce the saved peer, coordinator address, user and ports. SSH uses strict checking, only the dedicated identity, and the dedicated host-key store.
- RPC remains loopback on port 50052; RDMA is disabled and the llama.cpp revision remains `5bda51bfbc62e64193221e639f6ad4e08767d760`.
- Fixed a shutdown socket race found in the imported pairing cancellation test.

## Checks performed

- Combined Python suite: 74 tests, five platform/optional skips, no failures, with resource warnings treated as errors.
- Swift suite: 14 tests, no failures. Includes connection-field merge and model/runtime preservation.
- Tk initialized successfully in the project environment (9.0.4). Pool dependencies installed and lockfile updated.
- Side-by-side full Mac development bundle built at `app/build-pairing/Dyno.app`, including pool dependencies. Existing running bundle was preserved.
- Code signature verification passed for the development bundle; native dark/light snapshots rendered and the dark UI was visually inspected.
- A real selected-interface LAN discovery scan completed successfully and returned zero workers. This is not a successful peer discovery or pairing test.

## Live acceptance remains blocked

The discovery-enabled Windows package must launch through the machine's normal trust/signing process. Do not disable Application Control or substitute the older GUI build as evidence for discovery.

When the worker can launch:

1. Choose the trusted Private LAN interface, enable discovery, open pairing and start CUDA0.
2. On the coordinator select the matching LAN, find the worker, compare the full code on both devices, and approve setup.
3. Verify the saved connection is used by Test devices; require local Metal plus remote RPC device output.
4. Select a small GGUF and run actual generation. Save coordinator allocation/offload logs, response/timing, worker runtime diagnostics and GPU activity during generation. Idle VRAM readings or device listing alone are not inference evidence.
5. Test cancellation, stop/restart and connection loss; confirm unrelated serving processes survive.
6. Only after this one-to-one test passes, expand scheduling/testing to multiple workers or clients.

No GGUF was found in the checked local Hugging Face cache during preparation. A GGUF must be selected before the live inference test. No model was loaded for these checks. No real IPs or credentials are included in this report.

## SSH endpoint recovery integration — 2026-09-11

Merged the Windows endpoint-fix handoff selectively, retaining the Mac's saved-record, local-address and file validation. Both Test devices and Start pool use the shared recovery runtime. Legacy port-22 pairings authenticate on port 50054 with the existing identity, pinned host key and original host alias; no saved pairing files are rewritten. New pairing records support validated nondefault SSH ports and bracketed known-host entries. Imported the updated Windows setup helper; its Windows validation is reported by the handoff, not rerun on macOS.

Validation: full Python suite passed (79 tests, 5 skipped); after adding coverage for new-port and manual connections, all 17 pairing tests passed. Development app rebuilt, signature verified, installed locally and restarted. The installed bundled runtime authenticated at port 50054; byte comparisons confirmed identity, known_hosts and connection.json were unchanged.

Live Test devices opened the authenticated tunnel but failed during the RPC HELLO handshake with “Remote RPC server crashed or returned malformed response.” Accelerator discovery did not complete and no GGUF weights were loaded. Actual inference and GPU-use acceptance remain pending worker-side diagnostics. No release was published.

## Live worker retry — 2026-09-11

After the worker was started, the installed bundled runtime's Test devices passed through recovered SSH port 50054. It listed local MTL0 (Apple M5 Max) and remote RPC0, with 30,991 MiB free on the worker at discovery. The earlier HELLO failure occurred while the worker was stopped.

Started the downloaded Qwen3-0.6B-Q8_0 GGUF with the saved configuration (2,048 context, loopback API). A five-token prompt generated 32 tokens successfully. The first run reported 39.09 generated tokens/second. A second run with diagnostic verbosity 4 reported 49.93 tokens/second; these short samples are not a comparative benchmark. Its allocation log showed RPC model buffer 111.62 MiB, KV buffer 56 MiB and compute buffer 28.01 MiB, alongside local Metal buffers and three graph splits. This provides coordinator-side evidence of remote allocation and successful inference across the configured backends. Independent Windows GPU utilization sampling, larger-model testing and disconnect acceptance are still pending.

Both test coordinators were stopped after generation; the separate worker was left running. Saved trust and pool configuration were not edited. No release was published.

## Live worker telemetry and search UI — 2026-09-11

The first telemetry attempt was rejected by SSH as administratively prohibited. After Windows upgraded the existing paired key's allowed forwarding destinations, a fresh strict SSH connection successfully forwarded worker loopback port 50055. The worker's selected GPU UUID matched the RPC device identifier in validated samples. No trust key was replaced.

A short generation produced 512 tokens at 58.67 tokens/second with 11 fresh worker samples during/just after the request. Device-wide utilization ranged from 11–15%, peak sampled power was 56.38 W and peak sampled VRAM use was 2.419 GiB. These readings include other worker activity and are not a benchmark of exclusive Dyno utilization. Independent nvidia-smi comparison is being recorded by the Windows task.

Mac integration now polls bounded telemetry over the same owned SSH tunnel, rejects redirects and invalid samples, backs off on unavailable telemetry, marks stale/repeated samples, resets charts for a new worker/GPU, and leaves inference working without telemetry. The pool dashboard displays the real remote chart, VRAM, temperature, power and RPC state. Local GPU percentage is labeled active time, with clock and power, because it is time outside OFF residency rather than percent of peak compute.

Discover now filters MLX/GGUF, shows a searchable Downloaded library and format-appropriate Use in Models / Use in Pools actions. Live Hub queries and rendered screenshots were checked. Python: 84 tests passed (5 skipped); Swift: 18 tests passed.

A separate 142.15 GB Qwen3-235B-A22B Q4_K_M download/capacity test is pending. No large-model inference pass is claimed here.
