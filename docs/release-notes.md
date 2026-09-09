Dyno 0.2.0 turns the Mac app into an AI safety and alignment research workbench, with local MLX inference as its foundation.

## Research workflows

- Inspect activations in an already-serving model without loading another weight copy. See next-token probabilities and numeric activation norms on a shared color scale.
- Run isolated interventions, labeled linear probes and small SAE experiments, with held-out metrics and control baselines.
- Save activation captures and token analyses automatically. Reopen results and settings; rerunning creates a new record. Isolated job history also restores configuration.
- Choose Thinking: Default, On or Off beside Start, with per-request controls in Chat and Token analysis. Requires a compatible model template; raw-text research does not require thinking.
- Use the Python SDK, HTTP research APIs and eight local MCP tools. Documentation includes resident capture and resource/lifecycle constraints.

## Reliability and model management

- Preserve hybrid decoder metadata when tapping activations (fixes Qwen `is_linear` failures).
- Detect already-running Dyno endpoints and expose Stop controls, port selection and clearer resource checks.
- Resolve actual model paths when an endpoint advertises `default_model`.
- Keep native execution history bounded; explain skipped traces separately from inference failures and release history slots even when final response parsing fails.

## Install and upgrade

Download **Dyno-0.2.0-arm64.dmg**, open it, and drag Dyno to Applications. Requires **Apple Silicon and macOS 14+**. Python, MLX and the MCP launcher are bundled; model weights are separate. A SHA-256 checksum accompanies the DMG.

Existing inference processes need an explicit stop/start with this version to gain resident capture. Dyno does not automatically restart external servers. Check active requests before stopping. Previous unsaved session-only results cannot be recovered after closing the old app.

The app is ad-hoc signed, not Apple-notarized. See [Apple's first-launch guidance](https://support.apple.com/guide/mac-help/mh40616/mac).

These are experimental research tools, not safety certification. Resident capture returns activation norms, not individual-neuron interpretations or causal explanations. Probes, interventions and SAE training use separate workers and require adequate memory and quiet GPU capacity. SDK/MCP jobs and native app histories use distinct stores documented in the guide. LAN inference has no authentication; enable sharing only on trusted networks. Research and execution endpoints remain local-only.
