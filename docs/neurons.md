# Neurons: testing whether a model's units are clean

This tutorial tests one claim on a model you run yourself: that many of a language model's neurons are already interpretable, if you read them carefully. You capture every neuron at one layer over 2 million tokens of text, build an atlas of both poles of each neuron, and have one local model label them while a second local model scores the labels on text the first never saw. Then you train an SAE on the same layer, ablate activations by strength, and trace one answer back to the units that produce it.

Every step reports a baseline from the same pipeline: random directions, shuffled labels, random unit sets, or random ablations with the same mass or count. A number without its baseline means little.

These operations need a Dyno Lab build newer than 0.6.9. They run as ordinary Lab jobs, so the [SDK](sdk-guide.md), the [HTTP API](http-api.md#neurons) and the [local MCP bridge](local-mcp.md#neuron-tools) all reach them.

## Why test this

Nick Cammarata's essay [Neural Networks Are Already Clean](https://already-clean.goodfire.com/) (Goodfire) argues that individual neurons in language models are cleaner than their reputation: read each sign of a neuron separately, on its own scale, over broad enough text, and many of them have a short plain description. The essay credits Curt Tigges for the work on language neurons.

This page does not take the argument as settled. It turns it into measurements you can repeat on your own model, with baselines that can show it is wrong for that model, layer and corpus. One model, one layer and a few hundred labels are a test of the method, not a verdict about neural networks.

## What a neuron and a pole are

A gated MLP layer (Llama, Qwen, Mistral, Gemma) computes `down_proj(act(gate_proj(x)) * up_proj(x))`. The vector in the middle, the input to `down_proj`, has one coordinate per neuron. Qwen3-0.6B has 3,072 of them per layer. This is the `mlp_hidden` hook.

Because the gate and up projections are multiplied, a neuron's value can be positive or negative. The two signs often fire on unrelated text. Dyno treats them as two **poles** of the same unit and never merges them: each pole has its own maximum, its own examples and its own label. A neuron with a clean positive pole and a clean negative pole can look polysemantic when both are read together.

A **unit** is anything Dyno measures this way: a neuron, a random direction in the same space (the baseline), or an SAE feature.

## Hook sites

Every neuron operation takes `hook`. The default for neuron work is `mlp_hidden`. The older jobs (`inspect`, `compare`, `probe`, `sae`, `patch_sweep`) take `hook` too, with `block_output` as the default.

| Hook | What it reads | Basis |
|---|---|---|
| `block_output` | The residual stream after the layer | Residual dimensions, not neurons |
| `mlp_hidden` | `act(gate_proj(x)) * up_proj(x)`, the input to `down_proj` | One coordinate per neuron |
| `mlp_gate_pre` | `gate_proj(x)` before the activation function | Per neuron; with `mlp_up` it shows which factor set the sign |
| `mlp_up` | `up_proj(x)` | Per neuron |
| `mlp_output` | `down_proj(mlp_hidden)` | Residual dimensions |
| `attn_output` | The attention sublayer's output | Residual dimensions |

A hook wraps the module and leaves the model otherwise unchanged. For the MLP hooks, Dyno checks on a real prompt that the wrapped MLP reproduces the original output (relative error under 1%) before any job runs, so a wrong activation function fails loudly. Mixture-of-experts and other MLP shapes are refused.

## The fast path

The fast path is three jobs: capture, atlas, auto-interp. Only one Lab job runs at a time, so each waits for the last.

### 1. Start two models

Auto-interp needs two local models: an **explainer** that writes labels and a **scorer** that checks them. Use two different models, so a label is not scored by the model that wrote it. In **Models**, start for example `mlx-community/Qwen3-8B-4bit` on port 8083 and `mlx-community/gemma-3-12b-it-4bit` on port 8084. Any two chat models work; record which you used.

The capture and atlas don't need them. Start them before step 4.

### 2. Capture layer 14

The subject model here is Qwen3-0.6B: small enough to capture quickly, with 28 layers. Layer 14 is in the middle.

```python
from dyno.sdk import Lab

lab = Lab()
model = "Qwen/Qwen3-0.6B"
capture = lab.capture(
    model, layers=[14], corpus="web-mix", tokens=2_000_000,
    units={"neurons": "all", "random_directions": 20},
)
done = lab.wait(capture["id"], timeout=6 * 3600,
                progress=lambda p: print(p["message"], p.get("eta_seconds")))
print(done["result"]["capture"]["layers"]["14"])
```

The `web-mix` corpus is 70% FineWeb-Edu, 15% Python code and 5% each Spanish, Chinese and Russian web text, fetched from Hugging Face and cached on your Mac. Text is split into training and held-out documents (20% held out) before anything is computed. A source that can't be fetched is skipped, recorded in the result's `warnings`, and its share goes to the others. To use your own text, pass `corpus=[{"files": ["/path/notes.txt"]}]`.

The capture keeps, per unit and per pole, the 40 strongest examples with 32 tokens before and 8 after, samples across the activation range, 40 random samples, a histogram and how often it reaches each level. Held-out documents get their own strongest examples and random samples. For 3,072 neurons plus 20 random directions this is a few hundred MB, however many tokens you run. The capture saves a checkpoint every two minutes; if it is interrupted, submit the same settings with `resume_from` set to its id.

The result reports tokens, held-out tokens and `dead_units`: units whose two poles never reached 0.01.

### 3. Build the atlas

```python
atlas = lab.atlas(capture["id"])          # uses the capture's model for the tokenizer
lab.wait(atlas["id"], timeout=3600)

index = lab.atlas_index(atlas["id"], 14)
neurons = [u for u in index["units"] if u["kind"] == "neuron"]
strongest = sorted(neurons, key=lambda u: -u["negative"]["maximum"])[:5]
for u in strongest:
    print(u["unit"], u["negative"]["maximum"], u["negative"]["per_100_tokens"], u["negative"]["preview"])

page = lab.atlas_unit(atlas["id"], 14, strongest[0]["unit"], text=True)
for example in page["poles"]["negative"]["top"][:5]:
    print(round(example["value"], 2), repr(example["token"]), example["text"])
```

An atlas page shows each pole on its own scale: its maximum, how often it reaches 10%, 25% and 50% of that maximum per 100 tokens, its strongest examples, samples grouped by tenth of the maximum, and held-out examples. Rates are shown instead of percentiles because a unit that is near zero almost everywhere looks arbitrary in a percentile view: most of its percentiles are noise.

Read a few pages yourself before reading any label. Look at both poles. Look at the samples at 20–50% of the maximum, not only the top examples: a label that fits only the top 40 contexts describes the top 40 contexts.

### 4. Label and score 100 neurons and 20 random directions

```python
interp = lab.autointerp(
    atlas["id"], explainer=8083, scorer=8084,
    units={"neuron": 100, "random": 20}, condition="improved",
)
done = lab.wait(interp["id"], timeout=12 * 3600)
summary = done["result"]["autointerp"]["summary"]
for kind in ("neuron", "random"):
    print(kind, summary[kind]["detection"], summary[kind]["shuffled_labels"])

rows = lab.autointerp_rows(interp["id"])
for row in rows[:6]:
    print(row["unit"], row["pole"], row.get("label"), (row.get("detection") or {}).get("balanced_accuracy"))
```

For each pole, the explainer sees its 20 strongest examples and two samples from each tenth of its range, with the tokens where it fires marked and scaled 1–10 against the pole's maximum. It writes one short label. The scorer is shown held-out text only (fuzzing falls back to the training examples when a pole has none held out). For detection it gets the label and 10 numbered held-out texts, half the pole's strongest held-out examples and half random held-out text, and says which contain a strong activation. That is the **detection** score, as balanced accuracy. **Fuzzing** shows held-out strong examples with tokens highlighted, half at the real activations and half at random tokens, and asks which highlights fit the label.

A pole passes at detection balanced accuracy 0.75. 100 neurons are 200 poles; the 20 random directions are 40 more. Then every labeled pole is scored once more with another unit's label (`shuffled_labels`).

## SAEs and alignment

An SAE learns its own basis for the same activations. If neurons are already clean, many SAE features should be close copies of single neurons or small groups of them. The alignment measures that directly.

```python
sae = lab.sae_train(model, 14, corpus="web-mix", architecture="topk", expansion=4, k=32,
                    tokens=20_000_000, seeds=[0, 1])
done = lab.wait(sae["id"], timeout=24 * 3600)
for report in done["result"]["reports"]:
    print(report["seed"], report["fvu"], report["l0"], report["dead_on_heldout"], report["ce_loss_recovered"])
    print(report.get("alignment"))    # the first seed only
alignment = lab.sae_alignment(sae["id"])
```

At `mlp_hidden` on Qwen3-0.6B, `expansion=4` gives 12,288 features over 3,072 neurons. Architectures are `topk`, `batchtopk` and `relu` (L1). Training streams activations from the model into a shuffled buffer; nothing is written to disk first. Each seed trains its own SAE; with two or more, `seed_spread` shows how much the metrics move between seeds.

Evaluation uses held-out documents only:

- `fvu`: fraction of variance unexplained. 0 is a perfect reconstruction.
- `l0`: features active per token.
- `dead_on_heldout`: features that never fired on held-out text.
- `ce_loss_recovered`: next-token loss with the SAE's reconstruction in place of the hook. 0 is as bad as zeroing the hook, 1 is as good as the original.

For every live feature, the alignment gives its best single neuron by correlation, the R² of its best 1- and 5-neuron fits, and how much of its decoder vector sits in its top 1 and 5 neurons. A feature is a **candidate new building block** when no neuron correlates above 0.5 with it and no 5-neuron fit reaches R² 0.5. `alignment["neurons"]` goes the other way: the features each neuron takes part in.

To label the SAE's features with the same pipeline, capture them as units and run auto-interp on kind `sae`:

```python
features = lab.capture(model, layers=[14], tokens=2_000_000,
                       units={"neurons": None, "random_directions": 20, "sae": sae["id"]})
lab.wait(features["id"], timeout=6 * 3600)
feature_atlas = lab.atlas(features["id"])
lab.wait(feature_atlas["id"], timeout=3600)
feature_interp = lab.autointerp(feature_atlas["id"], explainer=8083, scorer=8084, units={"sae": 200, "random": 20})
done = lab.wait(feature_interp["id"], timeout=12 * 3600)
print(done["result"]["autointerp"]["sae_new_building_blocks"])
```

`sae_new_building_blocks` counts the features that are interpretable (they pass detection) and are also candidate new building blocks. That share is the closest single number to the question "what does the SAE find that the neurons don't?" It is small only if most interpretable features copy neurons.

## Ablation by strength

Do a unit's weak activations matter, or only its strong ones? The ablation job zeroes activations at every position on every forward pass and measures what changes on held-out text.

```python
ablation = lab.ablate(model, layers=[14], corpus="web-mix", eval_tokens=100_000)
done = lab.wait(ablation["id"], timeout=6 * 3600)
for row in done["result"]["ablation"]["conditions"]:
    print(row["name"], row["removed_entries"], row["removed_mass"], row["top1_changed"], row["kl"], row["ce_delta"])
```

The default conditions:

| Condition | What is zeroed |
|---|---|
| `weak-75` | Each unit's activations below its 75th percentile of \|value\| |
| `weak-75 random (mass-matched)` | A random set of activations removing the same expected \|value\| mass as weak-75 |
| `weak-75 random (count-matched)` | A random set removing as many activations as weak-75 |
| `strong-7` | Each unit's activations above its 93rd percentile |
| `strong-7 random (mass-matched)`, `(count-matched)` | The same two controls for strong-7 |

Percentiles and removed mass are calibrated on training documents. Effects are measured on held-out documents: the share of tokens whose top prediction changes (`top1_changed`), the KL divergence from the unablated model (`kl`) and the change in next-token loss (`ce_delta`), each with a 95% bootstrap interval over contexts.

Compare each condition with its own controls, not with each other. weak-75 removes three quarters of the activations but a small share of the mass. If it changes less than the count-matched control, the weak activations matter less than activations picked at random. If it changes about as much as the mass-matched control, mass alone explains its effect. `layers="all"` (the default) ablates every layer at once.

## From an answer to the units behind it

Attribution ranks units for one answer; ablation checks the ranking; steering checks what a unit does.

```python
prompt = "Every December, children leave cookies and milk for"
ranked = lab.attribute(model, prompt, " Santa", layers=[12, 13, 14, 15, 16], top=40)
units = lab.wait(ranked["id"])["result"]["attribution"]["units"]
for u in units[:8]:
    print(u["layer"], u["unit"], u["attribution"], u["direction"])

chosen = [[u["layer"], u["unit"]] for u in units[:8]]
test = lab.ablate_units(model, prompt, " Santa", chosen, control_seeds=10)
result = lab.wait(test["id"])["result"]["ablate_set"]
print(result["baseline_probability"], result["ablated_probability"], result["random_control_probability"])

layer, unit = chosen[0]
scale = {"atlas": atlas["id"]} if layer == 14 else {}   # the atlas covers layer 14
steer = lab.steer(model, "My favourite season is", [layer, unit], strengths=[-2, -1, 0, 1, 2, 4], **scale)
for output in lab.wait(steer["id"])["result"]["steer"]["outputs"]:
    print(output["strength"], output["text"])
```

`attribute` scores each unit by activation times the gradient of log P(target), summed over positions. It is signed: a unit pushing against the answer (`direction: against`) ranks as high as one pushing for it, so either pole can matter. The target must be one token; include the leading space.

`ablate_units` zeroes the chosen units at every position and reports P(target) and the top answers before and after. The control zeroes the same number of random units from the same layers, 10 times, with the range. The essay's example is this loop: it reports that removing 8 negative-pole neurons dropped P(Santa) to 6%, while removing the 20 neurons labeled Christmas or Santa only dropped it to 76%.

`steer` adds to one unit at every position while generating greedily. Strengths are multiples of the unit's positive maximum, read from the atlas when you pass `atlas` (it must cover that layer, from a capture of every neuron), or otherwise the unit's largest value on the prompts themselves. Strength 0 is the unchanged model. `scale="absolute"` adds the numbers as given.

## 2023-style versus improved auto-interp

The settings that separate the 2023-style method from the improved one are fields of the auto-interp job: which poles are labeled, how many examples the explainer sees, how much context, and whether it sees samples across the range. Run both on the same atlas, with the same seed so the same units are drawn, and pair them:

```python
old = lab.autointerp(atlas["id"], explainer=8083, scorer=8084, units={"neuron": 100, "random": 20},
                     poles="positive", stratified=False, condition="2023-style")
lab.wait(old["id"], timeout=12 * 3600)
new = lab.autointerp(atlas["id"], explainer=8083, scorer=8084, units={"neuron": 100, "random": 20},
                     poles="both", stratified=True, condition="improved", compare_to=old["id"])
paired = lab.wait(new["id"], timeout=12 * 3600)["result"]["autointerp"]["paired_with"]["neuron"]
print(paired)
```

`paired_with.neuron` compares the neuron poles both runs scored: the mean difference in detection score, each run's pass rate and a two-sided sign-flip permutation p-value. A 2023-style run scores positive poles only, so the pairing covers positive poles; the improved run's negative-pole results are in its own summary. Change one setting at a time if you want to know which one matters.

## HTTP

The same jobs over HTTP, on the Lab port:

```bash
curl -s http://127.0.0.1:8980/lab/v1/jobs -H 'Content-Type: application/json' \
  -d '{"operation": "capture", "model": "Qwen/Qwen3-0.6B", "layers": [14], "corpus": "web-mix",
       "tokens": 2000000, "units": {"neurons": "all", "random_directions": 20}}'
# While it runs, the job has progress: {message, fraction, eta_seconds, updated}.
curl -s "http://127.0.0.1:8980/lab/v1/jobs/$CAPTURE_ID"
curl -s http://127.0.0.1:8980/lab/v1/jobs -H 'Content-Type: application/json' \
  -d '{"operation": "atlas", "model": "Qwen/Qwen3-0.6B", "capture": "'"$CAPTURE_ID"'"}'
curl -s "http://127.0.0.1:8980/lab/v1/jobs/$ATLAS_ID/atlas/14/index"
curl -s "http://127.0.0.1:8980/lab/v1/jobs/$ATLAS_ID/atlas/14/vocab"
curl -s --compressed "http://127.0.0.1:8980/lab/v1/jobs/$ATLAS_ID/atlas/14/1234"
```

Unit pages are sent gzip-compressed with `Content-Encoding: gzip`; `--compressed` decodes them. Examples hold token ids; the `vocab` page maps them to text.

An auto-interp job has no `model`:

```json
{
  "operation": "autointerp",
  "atlas": "PASTE_ATLAS_JOB_ID_32_HEX_CHARS",
  "explainer": {"port": 8083},
  "scorer": {"port": 8084},
  "units": {"neuron": 100, "random": 20},
  "condition": "improved"
}
```

Its rows are the `autointerp.json` artifact: `GET /lab/v1/jobs/{id}/artifacts/autointerp.json`. Every field and default is in the [HTTP API](http-api.md#neurons) and the OpenAPI document.

## What the numbers mean, and what they don't

- **Detection pass rate** is the share of poles whose label let a different model pick out strong held-out activations from random text, at balanced accuracy 0.75 or more. It means the label predicts where the pole fires strongly on new text. It does not mean the label is complete, that it explains weak activations, or that the model uses the unit for that purpose.
- **Random directions** are the floor for this pipeline on this atlas. If random directions pass nearly as often as neurons, the scorer is finding something easy in any direction, and the neuron pass rate says little. The gap between the two is the result.
- **Shuffled labels** check the scorer. A pole scored with another unit's label should fail. If shuffled labels pass often, the held-out texts are too easy to tell apart.
- **A label is a hypothesis.** It comes from one model's reading of about 40 contexts. Read the atlas page; test it with new text.
- **SAE alignment** counts features that copy neurons and features that don't. A candidate new building block is defined by thresholds (correlation 0.5, R² 0.5); change them and the count changes. It is not proof that the feature is something the model computes.
- **`ce_loss_recovered`** says how much of the model's behavior the SAE's reconstruction keeps, on this corpus. It is not a measure of how interpretable the features are.
- **Ablation effects** are averages over held-out tokens of one corpus. Zeroing is not the only possible ablation, and every layer at once is a large change. A small effect with an interval that crosses the control's is no effect.
- **Attribution** is a first-order estimate, not a measurement. `ablate_units` is the measurement. A drop in P(target) larger than the random control's range shows the units matter for this prompt; it does not show what they compute.
- **Steering** shows text at each strength with greedy decoding. Large strengths break any model; what a unit adds at moderate strengths is the evidence.
- **The paired comparison** tests the two settings on these units, this atlas and these two models. A p-value from 100 neurons is not a statement about every layer.

Write down the model, revision, layer, hook, corpus, token count, the explainer and scorer, and the seeds with any result. Each job records its configuration hash and provenance; keep the job ids.

## Agent interpreter

The one-shot explainer labels a pole from a fixed set of examples. The agent interpreter investigates first: it looks at examples, forms a hypothesis, and tests it by writing its own texts and measuring the unit on them, live, before it submits a label. Its label is scored exactly like the one-shot label, so the two compare pole by pole.

```python
agent = lab.autointerp(atlas["id"], explainer=8083, scorer=8084, layer=14, units={"neuron": 20},
                       explainer_mode="agent", agent_steps=16, agent_queries=8,
                       compare_to=improved["id"])
```

The agent has three tools:

| Tool | What it returns |
|---|---|
| `examples(kind, decile, count)` | Training examples with the unit's activation marked: the strongest, those at a decile of the pole's maximum, or random text |
| `activation(text)` | The unit's activation on every token of a text the agent writes, measured on the model in the Lab worker |
| `submit(label)` | Ends the investigation with its label |

It never sees the held-out documents the scorer uses: its tools read only training examples. After each investigation Dyno checks the transcript for held-out text and reports `heldout_leak` per pole and `heldout_leaks` in the summary; it should always be 0. The transcripts are the `agent-transcripts.jsonl` artifact. `paired_with` compares the agent's detection scores with the one-shot run's on the same poles.

The explainer model must call tools (any Dyno model server does, for models whose template supports tools). The agent runs in the Lab worker, next to the subject model, rather than in an agent test room: a room's tools run inside a container, which can't measure the model on this Mac.

## Recipe

A recipe runs a chain of Lab jobs one after another, each step using the jobs before it, and ends with one report: every step's summary and provenance (model and revision, hooks, corpus commits, seeds, prompt templates, thresholds), next to the recipe's hypotheses.

Two recipes are built in. Their thresholds are fixed in the recipe, before any run.

| Recipe | What it runs |
|---|---|
| `already-clean-fast` | Layer 14, 2M tokens: capture and atlas at 1,024-token contexts, auto-interp with the improved method (100 neurons and 40 random directions, both poles); a second capture at 64-token contexts and the 2023-style method on the same neurons, paired; the agent interpreter on 20 neurons, paired with the one-shot run; the weak-75 / strong-7 ablation on every layer |
| `already-clean-full` | The same at layers 4, 14 and 24 with 20M tokens and 300 neurons, plus a TopK SAE on layer 14 (three seeds), its neuron alignment, and auto-interp of its features to count new building blocks |

```python
run = lab.run_recipe("already-clean-fast", "Qwen/Qwen3-0.6B", explainer=8083, scorer=8084)
lab.recipe(run["id"])   # steps with their job ids and status; the report when it finishes
```

Over HTTP: `GET /lab/v1/recipes` lists the built-in recipes and past runs, `POST /lab/v1/recipes` starts one (`{"recipe": "already-clean-fast", "model": "...", "explainer": {"port": 8083}, "scorer": {"port": 8084}}`), `GET /lab/v1/recipes/{id}` reads it, and `POST /lab/v1/recipes/{id}/cancel` stops it. A custom recipe is `{"custom": {"title", "steps": [{"name", "config"}]}}`, where a config may use `"${step name}"` for an earlier step's job id. `"only": [step names]` runs part of a recipe.

The report's `format` is `dynolab-neurons`. It stays on this Mac; sharing it to Dyno Research is not supported yet.
