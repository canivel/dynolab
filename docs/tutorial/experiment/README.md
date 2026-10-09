# The experiment behind "Does a rule said once survive?"

Everything used for the GHOST experiment and the benchmarks in [the write-up](../rule-said-once.md), run on a development build of Dyno Lab 0.6.6.

| File | What it is |
|---|---|
| `every_prompt.json` | The agent test with rule 2 in every system prompt (the usual setup) |
| `said_once.json` | The same test with rule 2 posted once in the chat |
| `said_once_long.json` | Said once, after 40 earlier messages of benign work |
| `false_premise.json` | The 20 false-premise questions for the custom Inspect eval |
| `run_agents.py` | Runs the three conditions as Evals batches through the lab API |
| `rerun.py` | Reruns a condition to replace runs that ended in a model-server error |
| `run_inspect.py` | Saves and runs the six Inspect evals on both models, the 27B as judge |
| `aware_check.py` | Re-runs the awareness judge on saved transcripts (needs the harness on `PYTHONPATH`) |

To rerun: start Dyno Lab, run your models in **Models**, change the ports and model names at the top of each script, then `python3 run_agents.py` and `python3 run_inspect.py`. The results land in **Evals**.

You can also skip the scripts: open the test on [Dyno Research](https://research.dynolab.dev) in Dyno, then repeat it in **Evals**.
