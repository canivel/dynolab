Dyno Lab 0.3.0 brings larger local models into the research lab with an experimental LAN GPU pool.

## GPU pools and research

- Pair a native Windows NVIDIA worker using a full verification code and strict SSH host verification. Save and select workers without duplicate entries for the same verified device.
- Run supported GGUF models across Metal and the worker GPU. View actual model allocations, generation activity and live worker telemetry.
- Run activations, interventions, causal patching, probes and ReLU/TopK SAE experiments on the resident pool. Save results and learned artifacts; reload settings for another experiment.
- Download GGUF and MLX models with format filters, a downloaded library and pause/resume/cancel controls.
- Use the updated Python SDK, Lab HTTP API and local MCP, with separate app, pool, SDK and API guides.

## Verified example

Qwen3-235B-A22B Q4_K_M (142.2 GB) generated on a 128 GiB M5 Max coordinator and a roughly 32 GiB RTX 5090 worker. Layer captures crossed RPC and Metal. All nine research configurations, cancellation, artifacts, no-op controls and restored outputs passed. Native activation, probe and SAE runs and saved-result reloads also passed.

A short 128-token completion measured about 10.1 tokens/second; this is not a comparative benchmark. Loading took about 49 minutes on the tested network. CPU output tensors participate. Mapped memory is not resident RAM, and combined reported headroom does not guarantee a model fits. Swap already existed before the successful run and did not rise above its captured baseline.

Pool research is experimental, limited to supported layouts and bounded inputs. Probe/SAE fitting runs on the coordinator, not as distributed training. Toy experiment results are not safety certification or evidence of probe generalization.

## Install and upgrade

Download **Dyno-0.3.0-arm64.dmg**, open it and drag Dyno into Applications. Requires Apple Silicon and macOS 14+. Model weights are downloaded separately. Use the matching native Windows worker from https://github.com/canivel/dynolab-windows-client for the tested pool setup.

Stop active experiments and the pool before replacing the app. Existing model downloads and saved results stay in their data directories. Verify the release checksum and signing/notarization evidence accompanying the final DMG.
