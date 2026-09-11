# LAN pools preview (development only)

This is the first feasibility implementation, not part of the 0.2.2 release. It runs a **Mac coordinator + one trusted worker** through an SSH tunnel on the same directly connected private IPv4 subnet. Native Windows, WSL and Linux workers are intended targets; they still require real hardware acceptance testing.

RPC binds to loopback on the worker. The coordinator also exposes inference only on loopback. There is no public-IP mode, remote management API, automatic network scan or raw LAN RPC listener. TCP is used inside SSH; this preview does not use RDMA. Paired-device agents, admission control, resource reservations, graceful drain and distributed Lab hooks are future work.

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

The pinned Metal/RPC backend compiled on the development Mac. A temporary loopback RPC worker and llama-server device discovery completed successfully and were stopped afterward; no model weights were loaded. Python suite: 43 tests, four optional tests skipped in this environment; Swift suite: 12 passed. Native Pools snapshots were inspected. No cross-machine inference or Windows/WSL build has been verified yet.
