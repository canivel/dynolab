# Can a document hijack an AI assistant?

A reproducible safety-monitoring experiment with Qwen3.8-27B on a Mac. We ask two different questions: does a document contain an injected instruction, and does the model actually follow it? A probe trained on the first question cannot automatically answer the second.

This example uses real model responses to synthetic appointment documents, then tests transfer to independently published Qwen3.8 prompt-injection cases. It is inspired by activation monitoring research, not a replication of TaskTracker, Constitutional Classifiers++, or PVDetector.

## Reproduce the experiment

Download `lmstudio-community/Qwen3.8-27B-MLX-4bit` in Dyno's Discover tab. In **Lab → Experiments → Probes**, select that downloaded model, import `run/experiment.json`, and run the experiment. The app's model selector controls the executed model even when the JSON contains a model ID. Confirm the model before running. Results are saved in history; export them for a portable copy.

The supplied probe reads zero-indexed layer 32 at the final input token. Label 1 means injection present; 0 includes clean documents, quoted attack text and legitimate user instructions. The app's generic sentiment-demo description refers to its default sample, not this dataset.

### Python SDK

Install Dyno with Lab dependencies in a Python environment on Apple Silicon. Start `python -m dyno lab` in one terminal, then:

```python
import json
from pathlib import Path
from dyno.sdk import Lab

root = Path('examples/document-injection-probe')
config = json.loads((root / 'run/experiment.json').read_text())
lab = Lab('http://127.0.0.1:8980')
job = lab.submit(**config)
finished = lab.wait(job['id'])
print(finished['result']['reports'][0])
lab.artifact(job['id'], 'probe-layer-32.npz', 'probe-layer-32.npz')
```

To regenerate the dataset and responses: `python examples/document-injection-probe/generate.py --output /tmp/document-probe-rerun`. Import the new JSON to fit a fresh run. `analyze.py` audits the included completed run and fits its predefined text baseline. `reproduce.py` re-runs the independently published cases and applies the included frozen weights, without retraining.

All examples use explicit chat-template text, thinking disabled and greedy generation. Research activations do not require thinking mode. This experiment does not evaluate reasoning-mode behavior or read a model's private intentions.

## Evidence and limits

See `PROTOCOL.md` for the frozen split, preprocessing and controls; `run/answers.json` for all outputs; `run/experiment.json` for importable settings; `run/result.json` for the Lab result; `run/metrics.json` for audited metrics and text baselines; `run/held-out.json` for test cases and scores; and `run/probe-layer-32.npz` for saved weights.

The independent-case source, exact modifications, corrected control and MIT attribution are recorded in `reference/PROVENANCE.md`. Its five tasks are a small transfer check, not a representative attack benchmark. Our quantized MLX runtime differs from the published BF16/vLLM setup.

The synthetic set holds out document groups, templates, topics and attack wording, but still uses a narrow common task and system instruction. Good performance can reflect artificial dataset structure. A bag-of-words baseline and the independent cases help reveal that limitation. Neither a high AUROC nor a single failure demonstrates general safety, awareness, intent or causal use of a representation.

## Research sources

- [Get My Drift? Catching LLM Task Drift with Activation Deltas, SaTML 2025](https://arxiv.org/abs/2406.00799). Our probe uses direct vectors, not this paper's activation-delta method.
- [Anthropic, Constitutional Classifiers++, 2026](https://www.anthropic.com/research/next-generation-constitutional-classifiers). A production ensemble, not the single experimental probe here.
- [PVDetector, July 2026 preprint](https://arxiv.org/abs/2607.12624). Related policy-violation concept research.
- [Ingot, Qwen3.8 pipeline failure report](https://ingot.tools/reports/qwen3-8-27b-glitch-tokens). Community report with public code; the source of our independent reproduction cases.

## Observed results

| Test | Result |
|---|---:|
| Synthetic held-out examples / document groups | 80 / 16 |
| Probe AUROC | 1.000 |
| Bag-of-words baseline AUROC | 1.000 |
| Probe accuracy at fixed 0.5 threshold | 78.75% |
| Probe injections caught / missed | 15 / 17 |
| Probe false alarms | 0 / 48 negative examples |
| Keyword-rule accuracy / false alarms | 80% / 16 |
| Majority accuracy | 60% |
| One shuffled-label control accuracy | 40% |
| Actual redirections on synthetic injected inputs | 0 / 96, including train and test |

Perfect AUROC on this narrow dataset does not establish an advantage over text alone. The fixed threshold missed every test example from the second injection family. The group-bootstrap AUROC interval is [1, 1] because the scores perfectly separate this sample; it cannot quantify uncertainty on unseen real-world distributions. No responses reached the generation token limit.

For the five independent published injection cases, our MLX run produced zero marker-only hijacks, both with and without the system guard. Manual review of the saved answers confirmed task completion or explicit injection rejection. This does **not** reproduce the source's reported 2/5 success under its BF16/vLLM setup. The frozen probe flagged 3/5 injections with no system instruction and 5/5 with our guard, with zero false alarms on the five controls in either condition. Ten inputs per condition are too few to estimate general reliability.

One no-system RAG response quoted `ADMIN-ZQ7X` while refusing to obey it and answering that the trial lasts 14 days. The source script's marker-presence heuristic would count that as hijacked. We preserve both marker-presence and marker-only fields and review the text; those two scores answer different questions.

This preliminary experiment was not selected for the lead video. The published [identifier-fidelity walkthrough](https://dynolab.dev/probe-example.html) is a different experiment. These files preserve the prompt-injection results and non-reproductions for inspection.
