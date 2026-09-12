# Dyno Lab Worker for Windows (development preview)

A small desktop companion for sharing an NVIDIA GPU with Dyno Lab on a Mac in the same private LAN. The distributed backend is experimental. This source has not yet passed a Windows GPU acceptance test and is not an official downloadable release.

## Intended download experience

1. Download the Windows x64 ZIP from a future Dyno release and extract the entire folder.
2. Open `DynoWorker.exe`. Python, llama.cpp and CUDA runtime DLLs are packaged alongside it. A compatible NVIDIA driver is still required; the app reports driver/GPU detection failures.
3. In **Connect to your pool**, choose **Enable LAN discovery** on your trusted Private LAN. Open **Nearby workers** on the coordinator, select this worker, and compare the full verification code on both screens. See [PAIRING.md](PAIRING.md) for the preview coordinator window and setup steps. **Manual setup** remains available as a fallback.
4. Setup requires a local administrator account (approve using the same account), a Private network on the same subnet, and standard Windows OpenSSH configuration. Entra-only accounts/custom SSH installations need manual pairing. No passwords or private keys are collected.
5. Verified discovery pairing saves a dedicated SSH identity, verified host key and connection fields on the coordinator. Integrating the new window directly into the separate Mac development Pools interface is still pending; its reusable Python API and handoff steps are in PAIRING.md. Manual pairing still requires verifying the displayed SSH fingerprint.
6. Select the GPU, then **Start worker**. `Listening` means its loopback RPC socket is available; it does not mean a coordinator is paired or a model is loaded. Run **Test devices** in Dyno before starting a pool.
7. **Stop worker** or quit to stop the owned GPU process. This interrupts any active pool using it. Stopping the Mac coordinator does not stop this Windows worker.

No CUDA toolkit, Git, compiler, Python installation, model download, or terminal commands are needed by an end user of the packaged worker. Automatic discovery and two-screen pairing are now implemented, with local TLS/mDNS tests. Cross-machine discovery, Windows UAC/firewall setup and Mac inference acceptance still need to be completed. The source-only Mac companion needs its Python/Tk environment until integrated into the Mac app.

## Observability

The app polls NVIDIA every three seconds: GPU name, driver, total/used VRAM, utilization and temperature. These are device-wide metrics, including other applications. Unsupported measurements appear unavailable. State, PID and uptime describe the owned worker process. Logs retain at most 2,000 lines in memory. **Save diagnostics** exports the current process state, GPU snapshot and runtime logs; inspect these before sharing, because logs can contain local details. No telemetry is uploaded. Request/token counters, bandwidth and per-model allocation attribution are not yet available.

## Connection changes and removal

Setup installs Windows OpenSSH if missing, starts it and sets automatic startup. On a new OpenSSH install it disables the broad default firewall rule and adds a Dyno rule limited to the chosen Mac IP, matching Windows address and Private profile. Existing SSH/firewall rules are preserved and can grant broader access independently.

The added key is limited by source IP, forced command and forwarding destination `127.0.0.1:50052`. It is stored in Windows' shared administrator authorized-keys file; use only a trusted Mac and a dedicated pool key. Existing key entries are retained. Setup restricts this file's permissions to SYSTEM and Administrators, including removal of any extra explicit permissions. Re-pairing the same Mac IP replaces its Dyno entry. A changed DHCP address requires re-pairing and removal of the old entry.

To revoke access, remove the matching `dyno-worker-…` line from `%ProgramData%\ssh\administrators_authorized_keys` and its `Dyno-Worker-SSH-…` Windows Firewall rule. Stop the app first. OpenSSH is shared Windows infrastructure, so removing the worker folder does not uninstall or disable it. A revoke button and automatic pairing are follow-up work.

## Maintainer packaging

On Windows x64, install Visual Studio 2022 C++ Build Tools, CMake, Git, Python with Tk, and a CUDA toolkit compatible with the compiler/GPU. In Developer PowerShell run:

```powershell
.\worker\windows\build.ps1 -PrepareOnly
.\worker\windows\build.ps1
```

The default source/build cache is `%LOCALAPPDATA%\DynoBuild\w-5bda51b`; output is `%LOCALAPPDATA%\DynoBuild\dist`. `-WorkDirectory` and `-OutputDirectory` override these locations. Keep the cache on a short local path, even when the source ZIP was extracted under OneDrive or a deeply nested folder. `-PrepareOnly` needs Git alone: it initializes a cache repository, enables repository-local long paths, fetches only the pinned commit, and excludes `tools/ui` before checkout. It verifies the revision and excluded directory. Running it again is supported; old failed clones are left untouched.

The build pins llama.cpp to the coordinator revision, builds RPC/CUDA, packages the GUI with PyInstaller, includes runtime DLLs and license notices, and writes `%LOCALAPPDATA%\DynoBuild\dist\DynoWorker-windows-x64-preview.zip` plus its SHA-256. Launch `app\DynoWorker\DynoWorker.exe` inside that output directory. The bundled manifest detects accidental runtime corruption/version mismatch; it is not publisher authentication. Windows Authenticode signing is not configured. Apple signing credentials cannot sign this executable.

The default CUDA configuration targets the build machine's GPU architecture. The RTX 5090 validation build uses `120a`; it must not be advertised as supporting every NVIDIA GPU. Broader architecture builds and clean-machine validation are required for a general download.

For repeatable checks, run `python -m unittest discover -s tests -v` with `src` on `PYTHONPATH`, `.\tests\test_windows_setup.ps1`, and `python worker/windows/smoke-test.py '<output>\app\DynoWorker'`. The smoke test requires port 50052 to be free and removes toolkit locations from its process environment. It tests the real backend lifecycle, not GUI interaction or distributed inference. See `WINDOWS-TEST-RESULTS.md` at the source root for the exact results and Mac-side checklist for this copy.

Before publishing: build on Windows, verify CUDA redistributable licensing/notices and all DLL dependencies, scan/sign the package, and test on a clean Windows machine with only the NVIDIA driver installed. Test UAC cancellation, standard/admin account behavior, SSH key restrictions, Private/Public firewall profiles, start/stop/restart, missing driver, GPU load, disconnect and app exit. Do not label this production-ready or publish it automatically from untrusted PRs.
