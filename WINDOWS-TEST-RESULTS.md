# Native Windows worker test results

Date: 2026-09-11. Development preview; not a release or a completed distributed-inference acceptance test.

## Discovery and pairing update (latest build)

The results below this section describe the earlier, preserved worker build. Its GUI pass does **not** apply to the new discovery build.

- Implemented interface-scoped mDNS discovery, a five-minute pairing window, TLS 1.3 with a full matching verification code on both screens, dedicated coordinator SSH identities and pinned host-key storage. Raw RPC remains loopback-only and travels over strict SSH.
- Added shared `discovery.py`, `pairing.py`, and `pair_app.py`; updated the Windows worker UI, coordinator runtime/CLI, elevation helper, Windows setup/build scripts and dependency packaging. The redundant experimental acknowledgement was removed and the primary UI uses coordinator terminology.
- Added `worker/windows/setup-discovery.ps1` for program-scoped Private/LocalSubnet discovery and pairing firewall rules. It has not been executed against the live firewall. No real SSH keys, services, or network profiles were changed.
- Python suite: **24 PASS**, no skips or resource warnings, including real loopback TLS and mDNS, matching codes, rejection on either side, malformed/oversized input, expiry/cancellation, occupied-port protection and dedicated trust records. Loopback fixtures do not prove cross-machine discovery or SSH. Temporary Windows ACL regression: **PASS**.
- Full native package rebuild: **PASS**, exit 0. `windows-discovery-build.log` contains the build output. The package uses zeroconf's supported pure-Python implementation; dependency licenses and unmodified zeroconf source are included.
- New archive: `dist/windows-discovery/DynoWorker-windows-x64-preview.zip`, 428700616 bytes, SHA-256 `0f24e56e93605fad8e8a4cd5b0aeda0a74fb8861c99cabe1384a0cb58b18a7aa`.
- New packaged GUI launch: **BLOCKED**. Windows reported “An Application Control policy has blocked this file” for both normal launch and `--pair`. No Windows protection was disabled. This version has not passed packaged GUI acceptance.
- The earlier GUI/runtime-tested archive remains in `dist/windows-tested/` with its original checksum.
- Source handoff: `dist/windows-discovery/DynoWorker-discovery-source.zip`. Merge the source changes into the Mac development checkout while preserving its unrelated work. This transferred copy lacks the Mac development Pools interface; the included standalone `python -m dyno pool pair` window demonstrates the shared integration. See `worker/windows/PAIRING.md` for setup and API details.
- Pending: resolve the executable's Application Control block through the machine's normal trust/signing process, choose the trusted Private LAN interface, then test one real coordinator/worker pairing, UAC cancellation/retry, scoped firewall and SSH rules, device detection and GGUF inference. Only after one-to-one acceptance should testing expand to multiple workers/clients. Both current Windows network profiles were Public; no choice has been assumed.

The previous manual instruction below to obtain an address/public key is now an optional fallback. The new pairing flow exchanges the public key and observes the peer address automatically after both code confirmations.

## Machine and toolchain

- Host: `wodai-gpu`; native Windows build 26200, PowerShell 7.6.5. No WSL or Mac execution.
- NVIDIA GeForce RTX 5090, 32607 MiB reported VRAM, driver 595.95.
- Git 2.55.0.windows.3.
- Initially no CMake, Visual Studio C++ tools, CUDA toolkit, or standalone Python were found.
- Installed Microsoft Visual Studio 2022 Build Tools 17.14.40 with the C++ workload and Windows SDK. Installer exit 0. Verified MSVC 19.44.35228 and CMake 3.31.6-msvc6.
- Installed NVIDIA CUDA 13.2 compiler/runtime/cuBLAS/Visual Studio integration components. Installer exit 0; `nvcc --version` reports 13.2.51. No display-driver install requested.
- Bundled test Python 3.12.14 runs unit tests, but Tk initialization fails because its `init.tcl` is absent. Importing tkinter alone is not a sufficient GUI preflight.
- Python 3.13.15 official installer SHA-256 verified. Per-user install failed with MSI error 0x80070003 at the app-redirected LocalAppData package cache. After user UAC approval, the machine installation completed with exit 0. Verified `C:\Program Files\Python313\python.exe` and successful Tk 8.6.15 initialization.

## Changes in this source copy

- `worker/windows/build.ps1`: short default cache/output paths; canonical directory resolution; `WorkDirectory`, `OutputDirectory`, `PrepareOnly`; shallow fetch of only the pinned commit; repository-local `core.longpaths`; sparse checkout before checkout; revision/UI exclusion checks; disable server/app/tests/examples/UI; missing-tool error; recognize CUDA 13.2's `LICENSE` file.
- `worker/windows/README.md`: preparation/retry commands and corrected output paths.
- `src/dyno/pool/worker.py`: report an already-exited child during Windows Job Object assignment as a startup failure; close/read the child log pipe when assignment fails before the reader starts.
- `src/dyno/pool/worker_setup.py`: fail explicitly on elevation cancellation/launch errors and on a missing or empty setup result.
- `worker/windows/setup-lan.ps1`: replace the authorized-keys DACL with only SYSTEM and Administrators access. The previous grant replacement left unrelated explicit ACEs in place. Existing file contents are retained.
- `tests/test_worker.py`: regression coverage for failed Job Object assignment and cancellation/missing setup results.
- `tests/test_windows_setup.ps1`: isolated real Windows file-ACL regression test; never touches real SSH keys, services or firewall rules.
- `worker/windows/smoke-test.py`: repeatable real-runtime start/stop/restart, occupied-port and unavailable-device checks with toolkit locations removed from PATH. Requires a completed package.
- `windows-smoke-results.json`: captured real CUDA lifecycle results and device-wide metrics; no credentials or LAN addresses.
- `windows-gui-diagnostics.json`: exported through the packaged GUI Save dialog while Listening; contains process state, GPU snapshot and runtime logs.
- `windows-build.log`: full packaging build output.
- This report.

## Tests and actual results

1. `hostname`, `$PSVersionTable`, `[Environment]::OSVersion.VersionString`: native Windows confirmed.
2. `nvidia-smi`: RTX 5090 and driver detected; device-wide metrics available. This is not proof of inference GPU use.
3. `.\worker\windows\build.ps1 -PrepareOnly`: PASS after allowing access to the requested LocalAppData cache. Repeated execution: PASS. HEAD is exactly `5bda51bfbc62e64193221e639f6ad4e08767d760`; `tools/ui` absent. Old failed clone under the transferred source left untouched.
4. `.\worker\windows\build.ps1`: first full attempt correctly stopped with `Missing build tool: cmake`. Toolchain installation followed.
5. Native CMake configuration with Visual Studio 17 2022/x64, `GGML_RPC=ON`, `GGML_CUDA=ON` and the requested disabled components: PASS. CUDA architecture is `120a-real` for this RTX 5090. RDMA disabled. `cmake --build "$env:LOCALAPPDATA\DynoBuild\w-5bda51b\cuda" --config Release --target ggml-rpc-server --parallel 4`: PASS, exit 0; produced `ggml-rpc-server.exe` and backend DLLs. Compiler warnings included upstream floating-point infinity conversions and linker LNK4098 (LIBCMT conflict); no compiler workaround or upstream source edit was made. Inference is still required to assess runtime behavior beyond startup.
6. `$env:PYTHONPATH = "$PWD\src"; & '<bundled Python>\python.exe' -W error::ResourceWarning -m unittest discover -s tests -v`: PASS, 10 tests, no skips, approximately 1 second. Before fixes: 8 tests ran, one failed with WinError 5 on immediate child exit and an unclosed stdout warning. These lifecycle tests use a real Python socket child, not the CUDA binary.
7. `.\tests\test_windows_setup.ps1`: PASS. Extra explicit Everyone ACE removed, inheritance disabled, only SYSTEM/Administrators grants remain, existing file contents preserved, temporary fixture cleaned up.
8. Network-profile inventory: both returned profiles are Public. No sshd service found. No real SSH/firewall/authorized-key changes have been made.
9. Real-runtime staging smoke test: PASS, exit 0. Copied the compiled executable/backend DLLs, CUDA runtime/cuBLAS DLLs and MSVC redistributable DLLs into `%LOCALAPPDATA%\DynoBuild\w-5bda51b\smoke-app\runtime`, with a pinned SHA-256 manifest. Ran `& '<bundled Python>\python.exe' worker/windows/smoke-test.py "$env:LOCALAPPDATA\DynoBuild\w-5bda51b\smoke-app"`. The harness replaces PATH with Windows System32 and removes CUDA_PATH variables. Verified real CUDA0 startup, Listening, stop/restart, occupied-port rejection without disturbing the test listener, and CUDA999 startup failure. Runtime logs show RTX 5090, TCP, endpoint 127.0.0.1:50052. No model was loaded. This is a runtime staging test, not a completed PyInstaller package or a driver-only clean-machine test.
10. After smoke-test cleanup, no `ggml-rpc-server` process or listening socket on port 50052 remained. Results saved in `windows-smoke-results.json`.
11. Full `.\worker\windows\build.ps1` from the developer environment below: PASS, exit 0, with Python 3.13.15 and PyInstaller 6.22.2. ZIP size 423456960 bytes; SHA-256 `d7ba0776ab684379c07a667fda9c49b8c7b472ff3eadf48f9c268c4e71c1d34e`. Recomputed and verified against the generated `.sha256` file. A verified transferable ZIP and checksum are also in `dist/windows-tested/`.
12. Re-ran all 10 Python tests using installed Python 3.13.15: PASS, no skips. Re-ran `worker/windows/smoke-test.py` against the completed `dist/app/DynoWorker` package with toolkit paths removed: PASS. `windows-smoke-results.json` now contains this packaged-runtime run.
13. Packaged GUI: PASS for launch, RTX 5090/CUDA0 detection, updating device-wide metrics, acknowledgement-required guard, Start to Listening, disabled GPU selection while running, Stop confirmation/Stopped state, restart to Listening with a new PID, runtime-log display, and diagnostics export to `windows-gui-diagnostics.json`. Verified real listener address is only 127.0.0.1:50052. Quit confirmation while Listening successfully closes the app and its owned RPC child; no worker processes or listener remain. No model inference occurred.
14. Live UAC cancellation for LAN setup, live SSH/firewall scope verification, multiple GPU selection, driver-only clean-machine validation, and cross-machine GGUF inference: NOT YET PASSED. Cancellation/missing-result failure paths and key-file ACLs were tested separately as described above. No UI security prompt was automated.

Only `test_worker.py` was present in the transferred `tests` directory before changes. The prior Mac suite of 51 tests and `docs/pools-preview.md` are not present in this copy, so that suite/checklist could not be rerun here.

## Remaining acceptance work

- GUI-level occupied-port and missing-runtime presentations can be checked further; real packaged backend rejection/error behavior has passed the programmatic smoke test. Only one GPU is installed, so switching among multiple GPUs is untested.
- Choose the trusted LAN adapter/profile with the user. Current Public profiles should fail LAN setup; do not change an arbitrary adapter to Private.
- Obtain only the Mac private LAN IPv4 address and Ed25519 public key. Test actual UAC cancellation and retry. Verify key ACL and preserve unrelated key lines/configuration. Verify the Dyno firewall rule is TCP 22, Private only, exact Mac remote address and selected local address; raw RPC must never be opened.
- Verify packaged DLL resolution on a clean driver-only Windows machine. The current native `120a` CUDA build is not a universal NVIDIA package; broader GPU architecture support remains future packaging work.

To reproduce packaging in a native PowerShell session:

```powershell
$vsRoot = & 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' -latest -products * -property installationPath
Import-Module "$vsRoot\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vsRoot -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$env:CUDA_PATH = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2'
# Confirm the installed Python path first; this is the machine installer default.
$env:PATH = 'C:\Program Files\Python313;' + $env:PATH
python -c "import tkinter; r=tkinter.Tk(); r.withdraw(); print(r.tk.call('info','patchlevel')); r.destroy()"
.\worker\windows\build.ps1
```

The Codex desktop app redirects LocalAppData writes on this machine. Its running GUI resolved to `C:\Users\dcani\AppData\Local\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\DynoBuild\dist\app\DynoWorker\DynoWorker.exe`. For transfer or use outside that context, extract the verified ZIP in `P:\DynoWorker-source-preview\dist\windows-tested` to a normal local folder and run its `DynoWorker\DynoWorker.exe`. Keep the entire extracted folder together.

## Mac-side test instructions

1. Preserve the Mac development changes and use the same llama.cpp commit `5bda51bfbc62e64193221e639f6ad4e08767d760`, built with Metal and RPC. Do not replace this transferred copy with upstream main.
2. Connect both machines to the same directly connected private IPv4 LAN. Select the Mac LAN interface in Dyno Pools. Routed/VPN-only peers are unsupported.
3. Supply an Ed25519 **public** key to the Windows setup flow. Keep the private key on the Mac/default SSH identity or SSH agent. Never paste or export passwords or private keys.
4. Compare the SSH host SHA256 fingerprint displayed by Windows against the one presented on the Mac before trusting it. Do not disable strict host-key checking or accept an unverified scan result.
5. Start Windows CUDA0 and verify Listening on **127.0.0.1:50052 only**, with `GGML_RPC_NO_RDMA=1`. Use Dyno's verified SSH tunnel; do not bind RPC to a LAN address.
6. Run Dyno **Test devices**. Require both a local Metal accelerator and a remote RPC accelerator. Listing devices does not itself prove model allocation.
7. Select a small existing GGUF on the Mac (MLX weights cannot be reused), run a short generation with modest context, and record the allocation log plus generated text/latency.
8. Confirm model layers/allocations and actual computation on both machines using coordinator logs/Metal activity and Windows GPU utilization/VRAM while generating. Idle device-wide metrics alone are insufficient.
9. Test stop/restart and tunnel disconnect, confirm owned processes stop and unrelated services survive, then save diagnostics for both sides. Do not commit real addresses or credentials.

## Sources used for toolchain/setup decisions

- [Microsoft Visual Studio 2022 release history](https://learn.microsoft.com/en-us/visualstudio/releases/2022/release-history)
- [NVIDIA CUDA 13.2 Windows installation guide](https://docs.nvidia.com/cuda/archive/13.2.0/cuda-installation-guide-microsoft-windows/index.html)
- [Python 3.13.15 release and installer checksum](https://www.python.org/downloads/release/python-31315/)
- [Microsoft Windows OpenSSH configuration and key-file ACL requirements](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
