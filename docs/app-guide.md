# Use Dyno Lab on your Mac

Download the app, run your first model, and turn a question about its behavior into an experiment. **Start here if you want to use the native app.** You do not need Python or the SDK to follow this guide.

Dyno Lab is the research product; the installed macOS application is currently named **Dyno**. This guide covers the 0.2 research workflows. Images are actual app captures or cropped results from completed local experiments, not mock measurements. Some older captures have an earlier toolbar arrangement; the current navigation is described below.

[Download for Apple Silicon](https://github.com/canivel/dynolab/releases/latest) · [Python SDK](sdk-guide.md) · [HTTP API](http-api.md) · [Local MCP](local-mcp.md)

## 1. Download and install

**Requirements:** an Apple Silicon Mac (M-series), macOS 14 or newer, disk space for the application and a model, and enough unified memory for the model plus its runtime workspace. Windows and Linux computers can consume shared inference; this release's native app runs on macOS.

1. Open [GitHub Releases](https://github.com/canivel/dynolab/releases/latest).
2. Under **Assets**, download the file ending in `arm64.dmg`. The `.whl` and `.tar.gz` files are for Python users, not the Mac installation.
3. Open the DMG and drag **Dyno** to **Applications**.
4. Open Dyno from Applications. Python, MLX and the local MCP launcher are already bundled. Model weights are downloaded separately.
5. Click the Dyno **menu bar icon** to open the main window. The app is a menu bar application, so the absence of a Dock icon is expected. Right-click its menu bar item for a compact performance summary.

The release includes a SHA-256 checksum beside the DMG. If you want to verify your download, run `shasum -a 256` on the downloaded DMG and compare the output with that file.

The current release is ad-hoc signed and not Apple-notarized. If macOS blocks first launch, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/guide/mac-help/mh40616/mac) only after checking that you downloaded the intended release.

![Dyno menu bar performance summary from a running workload](https://dynolab.dev/screenshots/menu-panel-dark.png)

*The menu bar summary gives a quick view of the running model and hardware; clicking the menu bar item opens the full app.*

## 2. Find your way around

| Place | Use it for |
|---|---|
| **Lab → Experiments** | Activations, interventions, labeled probes and small SAE experiments |
| **Lab → Token analysis** | Generated token probabilities and comparisons between two endpoints |
| **Execution** | Inspect inputs, model-emitted thinking, output and tool-call data for requests |
| **Models** | Select downloaded weights, set launch options, start or stop Dyno endpoints |
| **Discover** | Find and download MLX models |
| **Router** | Put one inference URL in front of multiple models and optionally share it on your LAN |
| **Performance** | Understand GPU load, memory, throughput and competing processes |
| **Chat** (top right, or ⌘J) | Talk to a running model and continue saved conversations |

For your first session, follow **Discover → Models → Chat → Lab**. Lab opens first because it is the research workspace, but it needs a model before it can collect measurements.

## 3. Discover and download a model

Start with a small MLX model so you can complete the workflow quickly. The examples below use `mlx-community/Qwen1.5-0.5B-Chat-4bit`; it is a demonstration model, not a recommendation for safety-critical work.

1. Open **Discover** and search for the model or repository name.
2. Check its size and precision. A 4-bit model typically uses less weight memory than a higher-precision variant; the runtime also needs workspace and context memory.
3. Choose **Download** and wait for completion. Do not start an experiment against a partial download.
4. Open **Models** and select the downloaded model. If you already have compatible weights elsewhere, use **Add folder** to include their directory in the local library.

![Discover showing downloadable MLX models, precision and sizes](https://dynolab.dev/screenshots/window-discover-dark.png)

*Discover lists model candidates. Downloading puts weights on disk; it does not itself load them into GPU memory.*

If the model does not appear in Models, refresh the library and confirm that the selected folder contains both configuration and weight files. A model being advertised by another server is not necessarily a downloaded model in Dyno's library.

## 4. Start, configure and stop a model

1. In **Models**, select the weights in the left sidebar.
2. Choose an unused **Start on port**, such as `8971`.
3. Choose **Thinking: Model default / On / Off** beside Start. This is a default for the next server launch, not a switch that changes an existing process.
4. Expand **Launch options** if needed, then click **Start**. Wait until loading finishes and the endpoint is shown as serving.
5. Open Chat or send requests to the displayed local URL.

![Models with a running endpoint, Thinking selector, Stop control and throughput](https://dynolab.dev/screenshots/docs-models.png)

*This running-workload capture shows where to choose Thinking and stop an endpoint. Port numbers and model names will differ on your Mac.*

| Setting | What changes | First-run advice |
|---|---|---|
| Max tokens | Default generation budget | Keep it modest for initial tests; thinking also consumes output budget |
| Prompt cache | Number of cached prompt entries | Keep the default until you measure your workload |
| Decode/prompt concurrency | Number of requests processed together | Larger values can require more memory; begin with defaults |
| Temperature, top-p, top-k | Sampling defaults | Use controlled settings when comparing outputs |
| Trust remote code | Allows supported model-loading code from a model repository | Enable only when required and when you trust that repository |

**Thinking support depends on the model's chat template.** Off may reduce latency for models that support disabling reasoning. Chat or an API client can override the server default per request. Raw-text activation capture bypasses the chat template and does not require thinking.

The **Running endpoints** list includes detected Dyno servers launched outside the app. Use the Stop button next to the intended endpoint. Stopping interrupts its active requests. Other runtimes are managed in their own apps. Dyno does not automatically stop an external server to make an experiment fit.

If Start reports an occupied port, select another port or stop the endpoint already using it. If the endpoint predates the current version, stop and start it explicitly to load new capture support; replacing the app alone does not update a process already in memory.

## 5. Chat with your model

1. Click **Chat** or press **⌘J**.
2. Select the running model. Start a new conversation and enter: `Explain in four short sentences why leaves are green.`
3. Send the message. Watch the answer arrive and inspect its throughput and time-to-first-token measurements.
4. Expand a thinking block if the model emitted one. No block means no separate reasoning text was returned; it does not prove the model performed no internal computation.
5. Use generation settings to change Thinking or sampling for subsequent messages. Continue the saved conversation or select another conversation from the sidebar.

![Native Chat showing a conversation and model output](https://dynolab.dev/screenshots/chat-dark.png)

*Chat saves conversations locally. The Router option, when enabled, lets the router choose a backend instead of sending directly to the selected model.*

To compare reasoning-on and reasoning-off behavior, use the same prompt in separate fresh conversations, record the settings, and allow enough output tokens. Changing sampling, context and Thinking simultaneously makes the comparison harder to interpret.

### Import a ready-to-run research example

The following sections include downloadable settings for the small Qwen model. Save the JSON file, choose the matching method in Lab, then click **Import JSON** under **Parameters & dataset**. Choose the model separately; importing settings does not download, start or switch models. Read the input before running. These files reproduce the demonstration configurations, not their exact outputs across every runtime version.

## 6. Capture activations

[Download example settings (JSON)](https://dynolab.dev/examples/inspect.json).

**Question:** what does the model predict after `The capital of France is`, and how do its hidden-state magnitudes differ across tokens and layers?

1. Open **Lab → Experiments** and choose **Activations**.
2. Set **Capture mode → Inspect serving model**, then select the serving endpoint. This reuses its loaded weights.
3. Enter `The capital of France is`.
4. Expand **Edit layers, settings & examples**. For the example model, use layers `[4, 8]` and `max_input_tokens: 128`. Layer indices start at zero; use indices that exist in your model.
5. Read **Experiment readiness**, then click **Run experiment**.
6. Inspect the next-token candidates, probabilities and activation grid. Try changing France to Japan and run again.

![Native activation result with next-token probabilities and numeric layer norms](https://dynolab.dev/assets/research-inspect.png)

*This recorded example was captured with the isolated method; resident capture offers the same norm grid and final next-token candidates, without intermediate logit-lens readouts or raw tensor files.*

**Read the output:** candidate probabilities describe the next token, not a complete generated answer. A space may appear as `·`. Each heatmap cell is the L2 norm of the block-output vector for one token at one layer. A brighter cell means a larger vector. It does not mean more attention, importance, confidence, or a named concept. All shown rows use the same color scale.

Resident capture accepts at most **four layers and 256 input tokens**. It runs a fresh raw-text forward pass, does not trace a different request, and can briefly delay serving because it shares the generation scheduler. It does not alter weights or serving caches.

To save raw activation artifacts or inspect intermediate logit-lens candidates, choose **Isolated experiment**, select a downloaded model and start the Lab service. That mode loads a separate model copy.

## 7. Compare interventions

[Download example settings (JSON)](https://dynolab.dev/examples/compare.json).

**Question:** does changing a layer's representation change the model's next-token prediction and continuation?

1. Choose **Interventions**. Select a downloaded model; this method uses an isolated worker, not the resident serving copy.
2. Start the Lab service with **Start lab**. Wait for idle GPU capacity and sufficient memory. If you stop serving to make room, do it explicitly in Models.
3. Use the same France prompt. Open the JSON settings and select layer `[8]`, intervention `scale`, and strengths `[0, 1, 1.5]` for the example model. Keep the token budget at `12` for a short comparison.
4. Click **Run experiment**. Compare the probability-change chart and each trial's baseline/intervention output.

![Measured intervention results including a zeroed state and unchanged neutral baseline](https://dynolab.dev/assets/research-compare.png)

*In this saved run, scaling to zero changes the continuation; strength 1 preserves the baseline. Your outputs depend on the exact weights and settings.*

The target-token probability is compared at the **same prompt prefix**. Generated continuations then run freely and can diverge. For scaling, strength 1 is the neutral control and strength 0 zeroes the targeted final-token block output. Other supported interventions include ablation, patching from donor text, and steering using a contrast between positive and negative texts. See [experiment parameters](http-api.md#experiment-parameters) before editing those inputs.

A changed output provides evidence about this particular intervention. It does not identify a complete reasoning circuit or establish that the model is safe.

## 8. Train a labeled probe

[Download example settings (JSON)](https://dynolab.dev/examples/probe.json).

**Question:** can a linear classifier distinguish positive and negative sentiment from a selected hidden representation?

1. Choose **Probes**, select the small downloaded model and start the Lab service.
2. Expand **Edit layers, settings & examples**. The template provides labeled training and test examples. Each entry needs `text`, binary `label` and `split` (`train` or `test`). Include both classes in both splits.
3. Use layer `[8]` for the example model. Keep test labels held out; do not move difficult test examples into training to improve the score.
4. Run the experiment. Examine held-out accuracy, AUROC, Brier score and the majority/shuffled-label controls.
5. Read the numbered examples beneath the chart to connect scores to inputs. Change one hypothesis at a time, then save a new run.

![Probe results showing held-out metrics, control baselines and example scores](https://dynolab.dev/assets/research-probe.png)

*This real run uses a tiny sentiment dataset to demonstrate the controls. The reported metrics are not evidence that it is a reliable safety detector.*

Accuracy measures correct predictions at a threshold. AUROC measures ranking discrimination. Brier score measures probability error (lower is better). Compare against the majority-class baseline and a shuffled-label control. A probe can reveal decodable information without showing that the model uses that information causally.

For meaningful research, use a larger dataset with a documented split and check for duplicate or near-duplicate examples across train and test. Results from the built-in toy example should guide learning the interface, not deployment decisions.

## 9. Explore an SAE

[Download example settings (JSON)](https://dynolab.dev/examples/sae.json).

**Question:** can a small sparse autoencoder reconstruct a layer's representations using a sparse feature space?

1. Choose **SAE sandbox**, select a downloaded model and start the Lab service.
2. Open settings. Supply representative text examples with explicit training/test splits, choose layer `[8]`, and begin with `features: 16`, `steps: 20` for a quick demonstration.
3. Run the experiment. Read the training-loss curve and held-out reconstruction MSE.
4. Check the mean number of active features and the dead-feature fraction.
5. Expand a feature to inspect example texts that activate it. Treat a possible semantic label as a hypothesis to test with new examples.

![SAE reconstruction curve and sparse-feature measurements in Dyno](https://dynolab.dev/assets/research-sae.png)

*The native SAE result shows a small ReLU/L1 experiment. It is not a pretrained SAE collection or a model-wide feature dictionary.*

Training loss alone is not sufficient: inspect held-out reconstruction and sparsity together. Dead features may indicate that training settings or data do not sufficiently exercise the feature space. The current implementation trains on final-token representations; it does not automatically assign verified concepts to features. Isolated artifacts include the learned weights and normalization information.

## 10. Analyze generated tokens

1. Open **Lab → Token analysis**.
2. Select a running model and enter `Explain in two sentences why B-tree indexes suit range queries.`
3. Choose a token budget and seed. Select **Thinking: Off** for a concise supported-model test, or On when specifically studying emitted reasoning.
4. Click **Analyze tokens**. Click a token to inspect its probability and alternatives. Review the lowest-probability tokens rather than reading a single average as quality.
5. Optionally choose a second running endpoint in **Compare with** and rerun. The divergence view shows where the generated token sequences differ.

![Token analysis with a completed real-model response](https://dynolab.dev/screenshots/docs-tokens.png)

*The example uses fixed-seed greedy generation. A different model, quantization, template or runtime can still produce a different sequence.*

Token probability is conditional likelihood, not correctness or safety. Alternatives reflect the returned top candidates, not necessarily the full vocabulary. Comparisons require both models to be running and may compete for GPU capacity. This method sends normal inference requests and does not load another model copy itself.

## 11. Save, reopen and continue studies

Activation captures and token analyses save automatically under `~/.mlx-dyno/research-history/`. Completed and failed runs retain their settings, model identity and returned results. Open **Saved activation captures** or **Saved token analyses**, select a run, adjust its restored settings, and rerun to create a new record. A matching running endpoint is needed to rerun; reading saved results does not load a model.

![Saved-result workflow illustrated by the native research workbench](https://dynolab.dev/screenshots/window-lab-dark.png)

*Isolated experiments have their own job history. Select a saved job to inspect its result and restore its configuration.*

Isolated jobs persist under `~/.mlx-dyno/lab/` and expose their artifacts through the Lab API. Use **Export experiment** to save a portable JSON copy of a selected experiment. Native app histories are not returned by `Lab.jobs()`; that method lists isolated jobs. Reopening restores evidence and configuration, not paused inference or optimizer state. Old results that were only in memory before automatic saving existed cannot be recovered after quitting that app version.

## 12. Inspect live Execution

1. Start a current Dyno endpoint. Send the leaves prompt from Chat or an API client.
2. Open **Execution**, select the request and expand **Request input & parameters**.
3. Follow lifecycle events and answer text while generation runs. If the model emits separate thinking or tool calls, inspect those sections.
4. Use **Pause** to freeze the display; this does not stop inference or capture. **Follow** keeps the selected trace in view. **Clear finished** removes terminal traces, not active ones.

![A completed request with its input, lifecycle events and generated answer](https://dynolab.dev/screenshots/docs-execution.png)

*Actual local Qwen request: “Explain in four short sentences why leaves are green.” The orange warning refers to other older endpoints needing a restart; the selected request completed. Tool-call data, when present, is not executed by this viewer.*

Execution is a bounded **in-memory** inspector: up to 64 traces per endpoint, with text/step limits. It is separate from saved research history. A skipped-trace counter means no history slot was available; it does not mean the inference request failed. If only a few requests are actually active but the count keeps rising, investigate stale running traces. Restarting an endpoint loses its execution history and interrupts its requests.

## 13. Route requests and share on your network

The router exposes one OpenAI-compatible URL in front of your running model endpoints. It does not launch those models for you.

1. Start the intended model endpoints in Models on distinct ports.
2. Open **Router** and click **Start the router**. Local clients typically use `http://127.0.0.1:8970/v1` with model `auto`.
3. Add explicit routing rules when you want predictable selection; enabled rules are checked in order. Self-routing uses a model to help classify a request. The cost model selects among candidates for a tier; escalation can retry on a stronger model when the configured token-probability threshold is not met. A token-probability threshold is not a correctness guarantee.
4. For a Windows, Linux or second Mac client, enable **Share on local network** and use the displayed **copyable client URL**. Apply any restart requested by the UI.
5. Click **Copy test**, paste the copied command into a terminal on the client computer and run it. Check Execution to see routing and output.

![Router controls and backend selection in the native app](https://dynolab.dev/screenshots/window-router-dark.png)

*The router view shows routing controls for running models. Use the address displayed on your own Mac; do not copy an address from a screenshot.*

LAN inference is unauthenticated: enable it only on a trusted network. Research and Execution APIs stay loopback-only. For WSL clients, use the Mac's LAN address, not `localhost`; confirm that Windows can reach the Mac, both devices are on the same reachable network, and the Mac firewall allows the server. With wired and Wi-Fi interfaces on Windows, routing may choose an unexpected interface. Test connectivity from Windows before debugging the WSL client. See the [API inference example](http-api.md#inference-and-lan-clients).

### Routing controls and client integrations

Use **Rules → Add** for the built-in coding rule: prompts matching `refactor`, `debug`, `stack trace` or `traceback` request the hard tier. Enable/disable each rule with its toggle or remove it with the trash button. Add currently creates this preset; it is not a general rule editor. **Self-routing** lets the strongest model tag the conversation; this adds a model call. **Cost model** chooses the fastest candidate meeting the tier. **Assume replies of** changes the expected response length used to compare candidates. Read **Decisions** after a request to see the selected backend and any escalation.

Under **Point a tool at this endpoint**, **Configure** writes the listed client configuration to use the router with model `auto`; **Rewrite** applies it again. Check the displayed file path and status message, then reload the client if required. This changes that client’s configuration, not the model weights. You can also configure its base URL manually using the copied router URL.

## 14. Read Performance and resource readiness

Open **Performance** during a generation. Compare decode tokens/second, time to first token, prompt throughput and cache hits with GPU utilization, unified memory, swap, bandwidth and power.

![Performance measurements during a running local model workload](https://dynolab.dev/screenshots/window-observe-dark.png)

*These are workload measurements, not hardware benchmark promises. Throughput varies with model, quantization, context, concurrency and other processes.*

Measured throughput comes from server instrumentation where available; estimated figures must not be treated as equivalent. The process list helps identify other workloads using resources. A Lab memory estimate includes workspace and reserve; it is not a reservation or guarantee against allocation failure. Isolated jobs count another weight copy; resident activation capture counts additional workspace only.

If Lab reports insufficient memory, choose a smaller model, lower the input budget, close competing workloads, or explicitly stop serving before the isolated job. If it reports active requests or a busy GPU, wait for a quiet period. Training alongside a continuously busy server is not currently supported by the app's admission checks.

## Troubleshooting and upgrades

| Symptom | What to check next |
|---|---|
| No main window after opening | Click the Dyno menu bar icon |
| Local model says “Choose model” | Finish downloading, refresh Models or add its folder; generic endpoint names may need a fresh capability lookup |
| Capture unsupported | Update the app and explicitly restart the old Dyno endpoint, then Refresh endpoint |
| Port already used | Stop the intended endpoint or choose a different port |
| Thinking does not change output | Confirm model-template support, request overrides and output budget |
| No token probabilities | Use an endpoint that supports chat logprobs; inspect its response/error |
| Separate-copy memory warning | Select a model before trusting the estimate; wait for idle capacity or stop serving explicitly |
| Old failure appears in history | It is a saved run; opening the service does not retry it. Restore settings and run a new experiment |
| LAN client cannot connect | Test Windows/Mac connectivity, copied LAN address, server binding and firewall before the API payload |

For an upgrade, download the new DMG, replace the application in Applications and reopen it. Plan endpoint restarts when traffic is quiet. Existing external processes do not acquire new Python code merely because the app was replaced. Keep exported experiments and their exact model/settings when comparing results across versions.
