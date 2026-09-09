Dyno Lab 0.2.1 adds Developer ID signing and Apple notarization for direct Mac downloads.

## Distribution and packaging

- Sign the app and bundled Python/MLX native libraries with hardened runtime and secure timestamps.
- Require Apple notarization acceptance and a validated stapled DMG ticket before generating release checksums.
- Keep the CLI launcher inside bundle resources and prevent Python bytecode writes from invalidating the app signature.
- Test the bundled CLI and MLX runtime, then verify the signature again before packaging.
- Keep release signing credentials out of PR jobs and use an ephemeral signing keychain in the release environment.

## Install and upgrade

Download **Dyno-0.2.1-arm64.dmg**, open it and drag Dyno into Applications. Requires **Apple Silicon and macOS 14+**. Python, MLX and the MCP launcher are included; model weights are separate. Verify the accompanying SHA-256 checksum.

The research features introduced in 0.2.0 remain available: resident activation capture, interventions, probes, small SAEs, token analysis, saved studies, SDK, HTTP APIs and local MCP. Research experiments are not safety certification.

This update does not automatically restart running inference servers. Stop and restart a server deliberately when ready to use the updated bundled runtime. Existing 0.2.0 release assets are unchanged.
