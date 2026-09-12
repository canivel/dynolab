# Nearby workers and verified pairing (development preview)

## Windows worker

1. Set the network you trust and share with your coordinator to **Private** in Windows Settings. Public connections are not eligible.
2. Extract the full ZIP and run DynoWorker.exe. Start worker now starts CUDA directly; the redundant acknowledgement checkbox was removed.
3. In **Connect to your pool**, click **Enable LAN discovery** and approve the one-time Windows firewall setup. No GPU RPC port is opened.
4. If multiple Private interfaces exist, select the network shared with the coordinator and click **Open pairing for 5 minutes**.
5. Open Nearby workers on the coordinator. Select the worker and click Pair. Compare **every group** of the displayed verification code, then confirm on both computers. Reject any mismatch.
6. Approve Windows SSH setup. Pairing automatically exchanges the coordinator's public key and the worker's verified SSH host key. No private key or password crosses the network.
7. After pairing, discovery closes. Use **Open pairing** for another coordinator. An enabled worker opens a five-minute pairing window on the next app launch; Stop discovery and quitting close it.

Discovery firewall rules are restricted to this executable, the Private profile and LocalSubnet: UDP 5353 (mDNS) and TCP 50053 (temporary TLS pairing). Existing unrelated rules are preserved. SSH setup adds a separate TCP 22 rule for the approved coordinator address. RPC remains **127.0.0.1:50052** with RDMA disabled and travels through verified SSH.

To remove discovery permissions, remove `Dyno-Worker-Discovery` and `Dyno-Worker-Pairing` rules. Remove `~/.dyno/worker-discovery-enabled` to stop automatic pairing windows on launch. Existing SSH pairing removal is described in README.md. Moving the app may require running Enable LAN discovery again because the rule is scoped to the executable path.

## Coordinator window and Mac handoff

This transferred copy does not contain the Mac development Pools interface. It now includes the shared modules and a standalone Tk pairing window. Transfer the changed source to the Mac without overwriting unrelated Mac development work. In its Python environment install the `pool` optional dependencies (`python -m pip install '.[pool]'`), then run:

```sh
python -m dyno pool pair
```

Tk must be available in that Python installation. The Windows package can open the same window with `DynoWorker.exe --pair` for UI/testing; model coordination still uses the existing Mac runtime.

The window finds multiple workers and pairs one selected worker at a time. Each accepted pairing is saved under `~/.dyno/pairs/<random-id>/` with a dedicated private SSH identity, `known_hosts` and `connection.json`. Failed attempts remove their newly-created local credentials. Unrelated SSH files are not changed.

Load `connection.json` into the pool configuration, then add the matching coordinator `binary` path and a local GGUF `model` path. The updated coordinator runtime accepts `pairing_id`, selects that dedicated identity/known_hosts file and retains StrictHostKeyChecking. It refuses a saved pairing whose peer, user or ports differ from the requested connection. Existing manually paired configurations still work.

For the Mac Pools UI, reuse `discovery.local_interfaces()` and `discovery.discover()` for the list, then `new_identity()`, `pair()` with a UI confirmation callback, and `save_pair()`. Merge the returned connection fields into the selected pool configuration before Test devices. Advertised labels are untrusted display text. The PairApp implementation demonstrates the full flow and failure cleanup.

A DHCP address change requires re-pairing in this preview because SSH key source restrictions and firewall rules use the observed coordinator address. Multiple worker records are supported; scheduling several simultaneous coordinators on one GPU is not implemented.

## Protocol and limits

- `_dynoworker._tcp.local.` publishes a name, GPU label, protocol version and pinned llama.cpp revision. Announcements contain no SSH keys, TLS keys, or verification codes. Only directly connected private IPv4 peers with the matching revision appear.
- TLS 1.3 uses a temporary self-signed certificate. The initial connection is **not authenticated by mDNS or a CA**. The two-screen check authenticates it before installation/trust persistence.
- The 128-bit code is the prefix of SHA-256 over a versioned domain label, the DER certificate, canonical coordinator hello (public key, nonce, name, protocol/revision), and a fresh worker nonce. Both sides calculate it locally. Comparing only a few groups is unsafe; compare the full code. This avoids relying on a brute-forceable short PIN and does not implement a custom encryption primitive.
- One connection is handled at a time. Messages are bounded to 8 KiB, handshake/user confirmation has deadlines, pairing expires after five minutes, and rejected/malformed/expired sessions cannot run setup. Windows verifies the current Private subnet again before installation. The peer address comes from the socket, not supplied JSON.
- The worker certificate key is generated locally, loaded into TLS, and its temporary files removed before listening. The coordinator private SSH key stays in a new private local directory. The worker returns only its public SSH host key over the confirmed channel.
- This is experimental application code, not an externally audited pairing protocol. Local tests do not substitute for the pending real Mac/Windows firewall, UAC and SSH/inference acceptance tests.

## Validation

Run the Python suite with `src` on PYTHONPATH in an environment with the pool dependencies. Tests exercise real loopback TLS and mDNS, matching codes, both rejection paths, malformed/oversized messages, expiration, cancellation, dedicated trust files and occupied-port protection. `tests/test_windows_setup.ps1` checks actual ACL behavior using only temporary files.

The package uses the supported pure-Python zeroconf implementation because an optional native wheel component was blocked by Windows Application Control on this test host. No Windows protection was disabled. Dependency licenses and the unmodified zeroconf source are included under `third-party/`. Rebuild against replacement zeroconf source by adjusting the pinned install in build.ps1; the worker source changes are available in the accompanying development source tree.
