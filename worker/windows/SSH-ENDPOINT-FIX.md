# Mac integration: recover the verified Windows SSH endpoint

Root cause on the test PC: a pre-existing IPv4 portproxy sends port 22 to a WSL SSH server. Native Windows sshd originally listened on IPv6; pairing returned the native Windows key, while the Mac's IPv4 connection reached WSL. This is a routing/service collision, not evidence that the saved native key needs replacement.

Windows repair is live: native OpenSSH now also listens on 50054. Existing port-22 forwarding was preserved. Setup checks the owning service and compares the actual IPv4 endpoint's Ed25519 public key with the local Windows host key before installing coordinator authorization or returning success. Its Dyno firewall rule is Private and restricted to the approved coordinator and local address, TCP 50054, native sshd executable. Raw RPC remains loopback 50052. The native Windows key matches the Mac's saved fingerprint (verified on the test devices).

Merge these changes into the Mac development checkout; do not overwrite unrelated Mac UI changes:

1. In `src/dyno/pool/pairing.py`, merge `save_pair`: validate the authenticated result's `ssh_port`, retain 22 as the legacy default, write `[address]:port` in known_hosts for nondefault ports, and save the port in connection.json. New Windows pairing results contain ssh_port=50054.
2. In `src/dyno/pool/runtime.py`, merge `resolved_ssh_args` and use it in `run` when spawning the tunnel. It handles existing paired records that still specify port 22 by testing port 50054 with the SAME existing identity and known_hosts, StrictHostKeyChecking=yes, and HostKeyAlias for the original saved address. No host key or saved file is replaced. Only a successful authenticated check selects the new endpoint; failure falls back to the original configured endpoint. It does not change manual unpaired configurations.
3. Ensure the Mac Test devices and Start pool paths both use this updated runtime. Restart/rebuild the Mac development app as its architecture requires. Keep native UI status messages for connection checking and errors. Do not disable strict host checks or instruct the user to delete known_hosts.
4. The existing saved worker should work without re-pairing or hand-editing files after this code is loaded. Run Test devices and then a small GGUF inference to verify that claim on the Mac; this Windows task has not executed that Mac check.

27 Windows Python tests and the Windows ACL test pass. New regression tests cover bracketed nondefault-port trust entries, invalid ports, and successful/failed legacy endpoint recovery without trust-file changes. Windows setup was executed successfully with the existing paired coordinator's public key; no replacement identity was created. Actual Mac authentication and inference remain pending.

OpenSSH permits multiple configured ports; Windows reads sshd_config when its service starts. References: https://man.openbsd.org/sshd_config and https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration
