# LAN pools preview (development only)

This experimental workflow is included in 0.3.0. It runs a **Mac coordinator + one trusted worker** through an SSH tunnel on the same directly connected private IPv4 subnet. Native Windows, WSL and Linux workers are intended targets; they still require real hardware acceptance testing.

RPC binds to loopback on the worker. The coordinator exposes inference only on loopback. Nearby discovery uses the selected directly connected private IPv4 network. Verified pairing uses the full code on both devices, then stores a dedicated SSH identity and host key for each saved worker. TCP is used inside SSH with RDMA disabled. Admission control, resource reservations, graceful drain and distributed Lab hooks remain future work.

## Nearby workers in the native Pools UI

1. Open **Pools**, choose the coordinator's **Local network**, then **Find workers**. On the worker, enable LAN discovery and open its five-minute pairing window. Announcements are untrusted until pairing completes.
2. Select a worker and click **Pair selected worker**. Compare all eight groups of the verification code on both devices. Reject a mismatch. Confirm on both devices and approve the worker's local connection setup.
3. Dyno saves a dedicated identity, verified `known_hosts`, and `connection.json` under `~/.dyno/pairs/<pairing_id>/`. Existing shared SSH files are not changed. Rejected/cancelled attempts remove their new local files. Cancellation after the worker has installed a key may leave that unusable remote key entry; remote rollback is not implemented.
4. The accepted connection is merged into the existing pool configuration, preserving the chosen model, backend binary, context and endpoint. **Saved workers → Use worker** switches connections individually; multiple saved records do not imply simultaneous multi-worker scheduling.
5. Download a model in **Models → GGUF → Find files → Download selected GGUF**, then click **Use in Pools**. Alternatively, use **Select downloaded GGUF** or **Choose GGUF** in Pools. Accept experimental RPC, then **Check plan**, **Test devices**, and **Start pool**. Both probing and inference use the selected pairing's dedicated identity and host-key file with strict checking. Changed addresses/users/ports or missing trust files fail closed; re-pair when network addresses change.
6. **Stop pool** interrupts requests and stops the owned coordinator/tunnel. Stop the worker separately in its own app.

The standalone preview remains available with `python -m pip install '.[pool]'` and `python -m dyno pool pair`. Tk must initialize successfully for that preview; the native SwiftUI flow does not require Tk. The full Mac app bundles the pool dependencies. See [Windows pairing](../worker/windows/PAIRING.md) and [Windows setup and packaging](../worker/windows/README.md).

For a side-by-side development build that preserves the running app: `DYNO_BUILD_DIR=build-pairing ./app/build.sh`. Open `app/build-pairing/Dyno.app` after quitting the older development app when traffic is idle. This is a development bundle, not a published release.

## Automatic recovery of a saved SSH endpoint

Both **Test devices** and **Start pool** check legacy port-22 pairings against the dedicated worker SSH port 50054. Recovery requires successful authentication with the existing dedicated identity and the already saved host key. The original address is used as the host-key alias; no trust file or saved connection is rewritten. If verification fails, the original endpoint remains subject to strict checking. Manual connections and newer pairings are not automatically redirected. New pairing results retain their verified SSH port.

An SSH tunnel opening does not prove the GPU worker works. **RPC device discovery failed** means the worker log and matching backend must be checked before inference can run.

## Manual configuration fallback

The commands below remain available for existing manually verified SSH setups. Omit `pairing_id` only when deliberately using that fallback. Do not copy a pairing identifier from another machine: its identity and verified host-key files remain local to its coordinator.

## Build matching runtimes

Build both ends from llama.cpp commit `5bda51bfbc62e64193221e639f6ad4e08767d760`. Install the compiler and CMake for your OS first. NVIDIA workers need the matching CUDA toolkit and driver; native Windows additionally needs the Visual Studio C++ build tools. Build instructions must be tested on the intended worker before claiming support.

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout 5bda51bfbc62e64193221e639f6ad4e08767d760
```

Mac coordinator:

```bash
cmake -S . -B build -DGGML_RPC=ON -DGGML_METAL=ON -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target llama-server ggml-rpc-server --parallel 4
```

NVIDIA worker (Windows developer shell, Linux or WSL with working CUDA):

```bash
cmake -S . -B build -DGGML_RPC=ON -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target ggml-rpc-server --parallel 4
```

The worker binary is normally `build/bin/ggml-rpc-server` on Linux and `build/bin/Release/ggml-rpc-server.exe` with a multi-configuration Windows generator. Verify the actual build output. Start the worker with the same user's account that SSH will reach:

```bash
./build/bin/ggml-rpc-server --host 127.0.0.1 --port 50052 --device CUDA0
```

Equivalent Python wrapper, after installing this Dyno development checkout on the worker with `python -m pip install .`:

```bash
dyno node --binary /path/to/ggml-rpc-server --device CUDA0 --experimental
```

Use the real executable path on Windows. The wrapper has no host override and always binds loopback. Stop it with Ctrl-C. Dyno's Mac Stop button stops the owned coordinator/tunnel, not this separately launched worker daemon.

## SSH and local networking

Enable an SSH server on the worker, restricted by its firewall to the intended LAN. Configure key-based login and verify the host key fingerprint directly on that worker before accepting it. Dyno requires an already trusted host and noninteractive key login; it never accepts a new key automatically or stores a password.

On Windows/WSL, the SSH server and RPC process must share the same network namespace: SSH into Windows does not automatically make WSL's loopback listener reachable. Prefer native Windows SSH + native Windows RPC, or an explicitly reachable WSL SSH server + WSL RPC. Dyno rejects routed/NAT addresses outside the Mac interface's subnet in this preview. Do not expose RPC through a broad port-forward to work around this.

With two active network adapters, use the private address on the same subnet as the Mac. **List LAN interfaces** shows the eligible addresses on the Mac. The selected address binds the SSH client, and route checks reject VPN/different-interface paths and routed gateways. The route and interface are rechecked during pool execution. This is a restricted local-network configuration, not a claim that SSH cures upstream RPC vulnerabilities. Only enroll trusted, nonsensitive test machines.

## Configure and run

Open **Pools** in the development app, edit the setup, and save it locally. Configuration is stored at `~/.mlx-dyno/pool-preview.json` with owner-only permissions. No actual IPs are committed to the repository.

```json
{
  "binary": "/path/to/llama-server",
  "model": "/path/to/model.gguf",
  "local_address": "",
  "peer": "",
  "user": "",
  "ssh_port": 22,
  "rpc_port": 50052,
  "port": 8978,
  "context": 2048,
  "alias": "dyno-pool"
}
```

1. Fill in your Mac LAN address, worker address and SSH username.
2. Choose a real GGUF model. Existing MLX model folders and loaded weights are not interchangeable with GGUF.
3. **Check plan** validates paths, required runtime flags, same-subnet membership and route. It does not load weights or reserve memory.
4. Accept the experimental trusted-worker checkbox, then **Test devices**. This opens an SSH tunnel and runs upstream device discovery without loading weights. Inspect the output for both local and RPC accelerators.
5. Start with a small model and idle machines. Startup discovers local Metal and remote RPC devices and rejects a file larger than their total reported free memory; this still does not budget KV cache or workspace. **Start pool** uses upstream memory-based layer placement with one inference slot and the configured context. Inspect the runtime log for actual layer offload. No speedup or successful use of both GPUs is inferred merely from a healthy endpoint.
6. Wait for the `ready` event. Test `http://127.0.0.1:8978/v1` with model alias `dyno-pool` using your existing OpenAI-compatible client.
7. **Stop** interrupts active requests and terminates only the coordinator and SSH tunnel launched by this operation. Closing the window retains the session; quitting the app causes its coordinator supervisor to clean up when it detects parent exit.

CLI equivalent:

```bash
dyno pool interfaces
dyno pool plan --config pool.json
dyno pool probe --config pool.json --experimental
dyno pool start --config pool.json --experimental
```

Port 8978 is in the existing router's scan range. A running router can discover the pool endpoint as a model backend; this does not add authenticated LAN inference sharing or distributed Lab support. Keep sharing disabled for this spike. Use the loopback endpoint for controlled benchmarks.

## Acceptance still required

Compare the same GGUF/settings on the Mac alone, NVIDIA alone and the pool. Record time to first token, prefill/decode speed, selected devices, memory on both machines and network traffic; include a long prompt and cancellation/disconnection. Confirm actual allocations and model output consistency. Then test a model beyond one device's memory budget. Do not use combined file sizes as an available-memory estimate.

Reference: [upstream RPC documentation and security warning](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md).

## Local validation

The native Mac + Windows RTX 5090 path now passes verified pairing, endpoint recovery, small-GGUF generation and fresh GPU telemetry. The 512-token run measured approximately 58.7 tokens/second with Metal and RPC model buffers in the backend log. This is a connectivity/placement test, not a speedup or large-capacity result. The 142.2 GB Qwen3-235B-A22B Q4_K_M model has now passed generation and the Lab API suite; native activation, probe and SAE runs also passed. See [the setup handbook](pool-guide.md) and [Mac integration results](mac-pairing-test-results.md).

## Live pool dashboard

After **Start pool**, setup collapses when the endpoint is ready. The dashboard shows connection/loading state, the selected GGUF, per-device model allocations, completed requests, generation activity and measured tokens/second for completed requests. Use **Pool setup** to reopen configuration; **Stop pool** stays available on the dashboard. **Run a prompt on this pool** sends a raw completion directly to this pool's loopback endpoint. It does not target an unrelated MLX endpoint.

The prominent **Reported GPU headroom** total adds the two backends' discovery values. Its breakdown and measurement time remain visible. Metal reports its recommended working-set budget minus allocations in the probing process; this is not system-wide free RAM. The worker reports free VRAM. Neither the sum nor file size guarantees that a model will fit: context, workspace, other processes and changing demand also matter. Values are snapshots before loading, not live free-memory measurements.

The coordinator GPU chart is live device-wide active residency (time outside the OFF state), including the desktop and other applications. It is not percent of maximum compute capacity; clock and power are shown alongside it. Upgraded workers expose utilization, VRAM, temperature and optional power over a second loopback-only SSH forward to port 50055. Enable telemetry for the existing paired coordinator key in the worker app. Missing telemetry does not stop inference: the card shows unavailable and retries after 30 seconds. Old/repeated samples become stale; worker or GPU changes reset the chart. Remote model allocation is parsed from actual backend logs. Request-speed bars are measurements per completed request, not instantaneous token rates. Session counters reset on a new operation; these are operational diagnostics, not saved Lab experiments.

**Presentation** hides setup, prompts, addresses and technical diagnostics for screenshots. Use real inference runs and retain measurement caveats. The optional snapshot fixture (`DYNO_POOL_LOG_FIXTURE` with `--snapshot … --pools-only`) replays an actual saved coordinator log and labels the view as a recorded session; the local utilization chart remains a separately labeled current device-wide sample. No unverified remote utilization or combined-memory performance claim should be used in marketing.

### Guided setup and capacity errors

Select a saved worker, choose a downloaded GGUF or browse for its file, then click **Start model on pool**. Selections save automatically. The **Selected** badge identifies the configured worker; selecting it does not start inference. **Add or re-pair a worker** and **Advanced settings** stay collapsed for routine use. Repeat pairings for the same address, coordinator network, account and verified host key appear as one worker, while existing identity files remain intact. Different verified keys remain separate.

Startup failures appear directly beneath the model name with the actual error and a recovery action. If RPC reports **0 MiB free** while telemetry shows an idle GPU with free VRAM, the runtime and telemetry disagree. Stop and start RPC in the worker app and run **Check devices** again. Do not re-pair or disable host verification to resolve a memory reading. The coordinator does not substitute telemetry for the allocator's capacity check.
