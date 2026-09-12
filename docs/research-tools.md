# Research tools and integration plan

Evaluated 10 September 2026. This document separates implemented Dyno features from upstream capabilities and proposed work. “Promising” means evidence of utility on particular tasks, not proof of general alignment or safety. Models, hooks, tokenizer revisions and quantization must match before transferring interpretation artifacts.

## What is implemented in this change

| Tool | Evaluated capability | Dyno implementation | Boundary |
| --- | --- | --- | --- |
| TransformerLens | Hook/cache interfaces, logit attribution, activation patching, architecture adapters | Native MLX clean/corrupted **Causal patching** experiment; target-minus-foil logit differences, site-level recovery and restored control. Attention export adapter for an existing upstream cache. | Block outputs only. No automatic PyTorch loading or head-level MLX hooks. |
| Neuronpedia | Feature atlas, examples, annotations, APIs, steering and graph exploration | **Research artifacts** fetches a public feature by model/source/index, plots examples, searches labels and saves local copies. Python converter also accepts downloaded feature JSON. | Fetch sends only entered public IDs. No prompt uploads, remote steering or automatic transfer of source labels to local neurons. |
| CircuitsVis | Interactive attention and token/feature visualizations | Native query/key attention heatmap and feature activation plots using a data-only JSON export. | One explicit attention layer/head per artifact. Does not embed upstream React or execute exported HTML/notebooks. |
| Circuit Tracer | Transcoder replacement models, feature attribution graphs and interventions | Python adapter exports an explicit induced subgraph; native directed-edge inspection, signed edge colors, node selection and saved provenance. | Generation stays in the external research runtime. Imported graphs are not recomputed or causally validated by the viewer. |
| SAELens | Training/inference, pretrained dictionaries and multiple SAE architectures | Native small **TopK** training option alongside ReLU/L1; adapter exports selected `sae.encode` activations for feature exploration. | No pretrained weight importer or claim of numerical equivalence to SAELens training. BatchTopK/JumpReLU and large-scale training remain external. |

All ordinary app launches now open the main window, including launches after first installation. Closing the window retains the existing menu bar behavior. Diagnostic and screenshot command modes remain separate.

## Why not install every library inside Dyno?

TransformerLens now documents a TransformerBridge path around Hugging Face/PyTorch models. Its MPS path is opt-in and may require CPU fallback. It does not turn an MLX weight allocation into a PyTorch model. Dyno’s resident server therefore cannot transparently become a TransformerLens model. A future external backend must disclose the second model copy and resource estimate. [TransformerLens getting started](https://transformerlensorg.github.io/TransformerLens/content/getting_started.html), [migration guide](https://transformerlensorg.github.io/TransformerLens/content/migrating_to_v3.html).

SAELens has architecture-specific normalization and decoder behavior. Dimension agreement alone is insufficient to apply a pretrained SAE to arbitrary MLX activations. A correct importer needs model/revision/hook/normalization checks and reconstruction parity against upstream output. The current implementation deliberately exchanges already-computed feature activations. [SAELens](https://github.com/decoderesearch/SAELens), [training documentation](https://github.com/decoderesearch/SAELens/blob/main/docs/training_saes.md).

Neuronpedia’s older docs explicitly warn that they lag current capabilities. The public feature endpoint used here was inspected directly; response identity and shapes are checked before saving. [Neuronpedia docs](https://docs.neuronpedia.org/), [public API example](https://www.neuronpedia.org/api/feature/gpt2-small/0-res-jb/0).

Circuit Tracer’s adjacency rows represent targets, columns represent sources; the adapter preserves that direction. Users select the subgraph explicitly and the export records omissions. Full circuit construction requires appropriate transcoders and upstream runtime support. [Circuit Tracer graph implementation](https://github.com/safety-research/circuit-tracer/blob/main/circuit_tracer/graph.py), [open-source overview](https://www.anthropic.com/research/open-source-circuit-tracing), [CircuitsVis](https://github.com/TransformerLensOrg/CircuitsVis).

## Use causal patching

Open **Lab → Experiments → Causal patching**. Choose an isolated model, enter clean and corrupted prompts of equal token length, and enter distinct single-token target and foil completions. Edit layer and token indices under parameters. The experiment runs at most 128 sites. It does not modify the serving model.

Each site replaces one corrupted block-output vector with the clean vector at the same position. The metric is target logit minus foil logit. Recovery is `(patched − corrupted) / (clean − corrupted)` and is undefined for a near-zero denominator. Values can exceed 1 or be negative; they are not percentages of a discovered circuit. The saved result includes a final unpatched control to verify restoration.

Python SDK:

```python
from dyno.sdk import Lab
lab = Lab()
job = lab.patch_sweep(
    model="/path/to/local/model",
    prompt="The capital of Italy is",
    clean_prompt="The capital of France is",
    target_token=" Paris", foil_token=" Rome",
    layers=[0, 1], positions=[3, 4], max_input_tokens=128,
)
result = lab.wait(job["id"])
```

Tokenization is model-specific: adjust positions after inspecting tokens. Do not infer token indices from whitespace. The defaults are an editable example, not a guaranteed token alignment across models.

## Bring external results into the Lab

Use the new `dyno.interop` module in an existing TransformerLens, SAELens or Circuit Tracer environment. It does not install those packages. Export JSON, then open **Lab → Research artifacts → Import artifact JSON**. Artifacts are saved in `~/.mlx-dyno/research-history` and can be reopened there in the UI.

```python
from dyno.interop import attention, sae_features, circuit_graph

# Supply tensors from your external experiment; each export is data-only.
# attention(tokens, attention_tensor[0, head], "attention.json",
#           model=model_id, source="TransformerLens: exact hook / layer / head")
# sae_features(tokens, sae.encode(states)[:, selected_features], "features.json",
#              model=model_id, source="SAELens: release / hook / revision",
#              feature_ids=selected_features)
# circuit_graph(graph, "graph.json", model=model_id,
#               node_indices=selected_nodes, labels=node_labels)
```

Limits: 8 MB per artifact; 128 attention tokens; 128 graph nodes/1024 edges; 256 feature series with up to 512 tokens each. Graph exports include original node IDs; supply meaningful labels from your source graph. This is a bounded viewer, not a renderer for arbitrary upstream JSON, `.pt` files or notebooks.

For Neuronpedia, expand **Fetch a public Neuronpedia feature**, enter its model/source/index and click Fetch. No network request happens merely by opening this workspace. The example `gpt2-small / 0-res-jb / 0` is public; its examples do not describe your currently served model.

## Neuronpedia example in the app

This native app view shows public GPT-2 feature examples fetched from Neuronpedia, with activation plots and saved artifact history. These are source examples, not activations from your currently served model.

![Neuronpedia feature examples in Dyno Lab](https://dynolab.dev/screenshots/neuronpedia-features-022.png)

## Prioritized research roadmap

| Priority | Feature to add | Research motivation | Acceptance criterion |
| --- | --- | --- | --- |
| P0 | Auditing study runner with blinded labels and held-out scenarios | AuditBench evaluates discovery of hidden behaviors; a screenshot or single probe score cannot establish auditing effectiveness. | Measure discovery, false positives, cost and generalization against a behavioral-only baseline. |
| P0 | Model/hook/revision compatibility registry and pretrained SAE importer | Gemma Scope 2 and Qwen-Scope make model-specific dictionaries useful for practical studies. | Numerical encode/decode parity; reject mismatched model/hook/normalization; quantify quantization drift. |
| P0 | Dataset-level patching with confidence intervals | Single-prompt patching is vulnerable to task and corruption choices. | Bootstrap intervals, clean/corrupted controls, random-site controls and held-out prompt templates. |
| P1 | SAE quality panel: sparsity–fidelity curves, loss recovery, stability | SAEBench evaluates several dimensions rather than reconstruction alone. | Compare architectures at matched sparsity; repeat seeds and held-out tasks; report downstream loss recovery. |
| P1 | External TransformerBridge backend and attention/head hooks | Broader architecture coverage without unsafe assumptions about MLX internals. | Explicit separate-memory budget, backend identity, tested hook maps and no-op output parity. |
| P1 | Graph-to-intervention workflow | Concept-targeted attribution connects probe decisions to circuit components; still early evidence. | Reproduce selected edge/node interventions and compare predicted effects with measured effects. |
| P1 | Persona/steering direction studies across conversations | Assistant Axis experiments suggest activation interventions can stabilize some behaviors. | Track capability regressions, adversarial robustness and out-of-distribution performance, not just target behavior. |
| P2 | Jacobian-lens adapter and sparse readout viewer | July 2026 J-lens research reports causal utility of particular internal representations. | Reproduce open-model readouts and swap/ablation controls; quantify faithfulness and uncertainty. |
| P2 | Natural-language autoencoder / introspection adapter comparisons | Recent work reports improved auditing on controlled tasks. | Compare to probes and behavioral baselines on blinded models; preserve evidence separate from generated explanations. |
| P2 | Auditing agents with replayable, bounded tool access | Automated auditing can make multi-step investigations repeatable. | Budgets, immutable evidence, held-out scoring, prompt-injection tests and explicit execution permissions. |

### Evidence behind the roadmap

- [AuditBench (2026)](https://alignment.anthropic.com/2026/auditbench/) and [auditing hidden objectives (2025)](https://www.anthropic.com/research/auditing-hidden-objectives): controlled auditing tasks motivate measuring actual discovery rather than treating interpretability output as assurance.
- [Gemma Scope 2](https://deepmind.google/models/gemma/gemma-scope/) and [Qwen-Scope, May 2026](https://arxiv.org/abs/2605.11887): pretrained dictionaries/transcoders support model-specific analysis and intervention experiments. Published benefits do not imply compatibility with every quantized checkpoint.
- [SAEBench](https://arxiv.org/abs/2503.09532): broader evaluation motivates multiple quality measures and baselines. [SAE steering study, May 2026](https://arxiv.org/abs/2605.31183) also highlights sensitivity to feature selection and labeling, so “SAEs always outperform” is not justified.
- [Concept-targeted attribution, August 2026](https://arxiv.org/abs/2608.27510): an emerging connection between probes and attribution graphs. Treat this as a recent preprint to replicate, not an established safety detector.
- [Assistant Axis, January 2026](https://www.anthropic.com/research/assistant-axis): directions and activation caps show useful effects in studied settings; transfer and side effects require evaluation.
- [Jacobian lens / global workspace, July 2026](https://www.anthropic.com/research/global-workspace): motivates an experimental readout backend with causal controls. It is not equivalent to exposing all thoughts or proving consciousness.
- [Natural Language Autoencoders (2026)](https://www.anthropic.com/research/natural-language-autoencoders) and [Introspection Adapters (2026)](https://alignment.anthropic.com/2026/introspection-adapters/): promising auditing aids whose descriptions still need independent validation.
- [A Pragmatic Vision for Interpretability](https://www.alignmentforum.org/posts/StENzDcD3kpfGJssR/a-pragmatic-vision-for-interpretability): useful prioritization perspective from Alignment Forum; roadmap choices above are Dyno implementation judgments, not claims of a field-wide consensus.

## Validation status

Native compilation, MLX hybrid-decoder worker integration, neutral and clean-recovery patch controls, TopK activity bounds, export orientation and malformed artifact rejection are covered by local tests. Those checks establish implementation behavior, not research effectiveness. Full PyTorch/TransformerLens/SAELens/Circuit Tracer execution is external and has not been validated end-to-end in this release. A cached Qwen1.5 0.5B 4-bit model also completed a four-site patch sweep with restored unpatched logits. The development app opened its window on launch; a UI-triggered Neuronpedia lookup saved 32 public examples. UI automation disconnected after the fetch; an offscreen native snapshot subsequently verified the loaded feature plots. Full interactive coverage remains limited.

## Worked example: reference corruption

The [Qwen3.8 identifier-fidelity experiment](../examples/identifier-fidelity-probe/README.md) includes importable Lab JSON, exact prompts, generated outputs, saved weights, SDK submission and HTTP commands. It uses the existing jobs and artifacts APIs. The probe predicts literal reference absence, not harmfulness or deceptive intent.
