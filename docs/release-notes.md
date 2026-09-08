Run local MLX models on Apple Silicon, measure their inference speed, and share them with other computers on your network.

- Native Models, Router, Inspect, Performance, and Discover views, plus Chat and menu bar telemetry.
- LAN sharing with automatically detected addresses, a copyable URL, and a test request.
- OpenAI-compatible inference, streaming, and automatic or explicit model selection.
- Router settings and request history remain local-only.

## Install

Download **Dyno-0.1.0-arm64.dmg**, open it, and drag **Dyno** to **Applications**. Requires **macOS 14 or later on Apple Silicon**. Python and MLX are bundled; model weights are downloaded separately.

The app is ad-hoc signed and **not Apple-notarized**. macOS may block the first launch; see [Apple's guidance](https://support.apple.com/guide/mac-help/mh40616/mac) before choosing whether to open it.

Click the menu bar icon to open Dyno; right-click it for a quick summary. To share a running model, enable **Router → Share on local network**, then click **Start the router**. Use only trusted networks: inference is available without authentication while sharing is enabled.

A SHA-256 checksum is included alongside the DMG.
