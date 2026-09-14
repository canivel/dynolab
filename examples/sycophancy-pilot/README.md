# Does Qwen3.8 agree when the user is wrong?

A small, reproducible feasibility study for Dyno Lab. Read [the protocol](PROTOCOL.md) before interpreting its results. The frozen prompts and all answers live under `run/`; no external judge service is used.

## Observed pilot result

All 36 first-line choices were correct: 12/12 neutral, 12/12 correct-belief, and 12/12 incorrect-belief. There were no malformed answers, no responses reaching the output cap, and no correct-to-incorrect paired flips. The explanations were reviewed for contradictions with the selected answers; none reversed the selected answer. This does not certify every explanatory detail.

This simple factual-pressure template did not elicit false agreement on these common misconceptions. No sycophancy probe was trained: the observed behavior labels contain no positive cases. This result does not establish that Qwen3.8 is immune to sycophancy. Read [every prompt and answer](run/REPORT.md), [machine-readable results](run/summary.json), and the [run manifest](run/manifest.json).

## Reproduce

Use an Apple Silicon environment with Dyno's serving dependencies (`python -m pip install '.[serve]'` from the repository root). The exact model revision in `run.py` must already be in the standard Hugging Face cache. This script deliberately refuses to download a missing model. Stop other model jobs first if memory is tight.

```sh
python -m unittest discover -s examples/sycophancy-pilot -p 'test_*.py'
HF_HUB_OFFLINE=1 python examples/sycophancy-pilot/run.py
python examples/sycophancy-pilot/report.py
```

Generation resumes saved cases rather than overwriting them, and refuses a different manifest. To run a fresh independent reproduction, preserve the existing `run` directory under another name first. Never merge outputs from different configurations. The report validates dataset hashes, response IDs, and scores before writing `run/REPORT.md`.

## Open actual activation captures in Dyno Lab

After generation exits, start the Lab API with `dyno lab --port 8980` if it is not already running, then:

```sh
python examples/sycophancy-pilot/capture.py
```

The two jobs are saved in the Lab service's experiment history. They inspect the neutral and incorrect-belief Australia prompts at block 32. They are fresh forward passes over the same serialized inputs, not recordings of the earlier completions. Exported configs, job IDs, results and tensors are retained alongside the behavioral evidence.

A heatmap shows activation magnitude. It does not by itself identify agreement, deception, or a causal mechanism. A probe requires observed positive and negative response labels and an independent evaluation set; this pilot does not automatically manufacture one from prompt conditions.

## Next research step

If easy factual questions show a ceiling effect, retain that result and use a separately registered study of Anthropic's [released persona-vector extraction and evaluation materials](https://github.com/safety-research/persona_vectors). Those materials include subjective questions and explicit trait instructions, so their labels require a different rubric. Agreement with a subjective opinion is not automatically false agreement.

The original method also requires averaged response activations and scoped steering. Neither a two-prompt direction nor a classifier recognizing the wording of pressure is a faithful replacement. See the [research roadmap](../../docs/safety-replication-roadmap.md) for the implementation gaps and controls.
