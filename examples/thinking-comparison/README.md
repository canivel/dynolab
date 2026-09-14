# What changes when thinking is enabled?

We ran six matched prompts on the pinned Qwen3.8 27B 4-bit model, each with thinking off and on. These are pilot questions, including explicit instructions designed to induce agreement. They are not a blind safety benchmark.

- All six thinking-enabled runs produced an explicit thinking section and a final answer.
- Thinking-off runs generated 340 tokens in total; thinking-on runs generated 1,101, including thinking text. Mean counts were 56.7 and 183.5 across these six cases. This is not a general latency or cost benchmark.
- Both positive-instruction cases still agreed strongly with the user's position when thinking was enabled. Negative-instruction cases and neutral cases retained qualifications. These are model-assisted qualitative observations, not independent ratings.
- All twelve prompt/thinking/answer replay captures succeeded. No response hit the 768-token limit.

Read [the protocol](PROTOCOL.md), [all generated text](run/REPORT.md), and [summary](run/summary.json). Explicit thinking can be useful to inspect, but it is not guaranteed to describe the computation that caused the answer.

## View it in the development app

Open **Lab → Research artifacts → Import artifact JSON** and choose one of the `*-artifact.json` files under `run/`. The viewer separates generated thinking, final answer and measured activation norms. Filter token sections and select a token to inspect its raw layer norm. Imports are saved in artifact history. This requires the updated development build; older releases reject the new `generation` artifact type.

The [native view screenshot](../../docs/assets/thinking-replay-view.png) renders saved real output and a fresh forward-pass capture. It is not a screenshot of live generation. There is no claim that a large norm identifies an intention, a safety issue, or confidence.

## Reproduce

With the development source and MLX serving dependencies available, and the exact model already cached:

```sh
HF_HUB_OFFLINE=1 python examples/thinking-comparison/run.py
```

The script preserves and resumes its saved run. Move the existing run directory aside before an independent repetition. Upstream prompts and licenses are in the sibling `persona-vector-pilot` directory. Generated thinking is parsed only from explicit delimiters; incomplete reasoning is never silently promoted to a final answer.
