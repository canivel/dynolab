Dyno Lab 0.2.2 expands the local interpretability workspace and opens the full app window on normal launch.

## Research workflows

- Compare clean and corrupted prompts with bounded causal activation patch sweeps, target-minus-foil logit changes and an unpatched restoration control.
- Train small TopK SAEs alongside the existing ReLU sandbox.
- Fetch public Neuronpedia feature examples explicitly, visualize their activations and save them for later.
- Import attention heatmaps, feature activations and directed circuit subgraphs into the new Research artifacts workspace.
- Export data from external TransformerLens/CircuitsVis, SAELens and Circuit Tracer workflows using `dyno.interop`.
- Run patch sweeps through the Python SDK, HTTP API and local MCP. Updated documentation includes a toolkit evaluation and research roadmap.

These adapters do not run upstream PyTorch backends, import pretrained SAE weights or automatically generate circuits. Public feature examples are not measurements on the currently served model. Research experiments are not safety certification.

## Install and upgrade

Download **Dyno-0.2.2-arm64.dmg**, open it and drag Dyno into Applications. Requires **Apple Silicon and macOS 14+**. The app is Developer ID signed and Apple notarized. Python, MLX and the MCP launcher are included; model weights are separate. Verify the accompanying SHA-256 checksum.

This update does not automatically restart running inference servers. Stop and restart endpoints deliberately when ready to use the updated bundled runtime. Earlier release assets remain unchanged.

## Validation

31 Python tests and 12 Swift tests, a real Qwen patch sweep with restored logits, native chart snapshots and CI builds passed during development. Full upstream backend execution has not been validated end-to-end.
