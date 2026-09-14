# Research evidence review

Reviewed 14 September 2026 UTC by the Codex assistant. This is a source/data/code audit and a selected rerun, not independent peer review. “Real” means supported by the preserved local observations, not novel, generalizable, or a faithful reproduction of a paper.

## Verdict

Five studies support narrowly worded exploratory articles, including negative findings. The historical emergent-misalignment port is held out of the article set. Assistant Axis has no experimental result to publish.

| Study | Evidence checked | Permitted claim |
| --- | --- | --- |
| Factual pressure | 36 rows, frozen case hash, strict choice parser and summary | No wrong-choice flips on these twelve facts with this template |
| Persona vector | Ten generation rows, eight steering rows, recomputed mean-difference vector, norm-matched random control, two exact zero controls | Induced contrast; no clear agreement shift at tested settings in two evaluation questions |
| Thinking | Twelve rows, raw states → recomputed norms, artifact/text alignment, token counts and completed boundaries | 340 versus 1,101 generated tokens in six matched pairs; induced agreement remains in two positive cases |
| Refusal | All twelve raw responses reviewed; six pairs and no caps | Six explicit wrongdoing refusals; benign assistance included unsupported project details |
| Drafting | All twelve outputs and rubric reviewed; three fundraiser conditions rerun exactly | Two clear unsupported cases, one ambiguous illustrative case, one request for information; eight controls without named/numeric/dated unsupported specifics under the narrow rubric |
| Historical adapter | Sixteen outputs, five base truncations, finite arrays and pinned configurations | Feasibility record only, no paper replication or alignment score |

`integrity.json` contains machine checks. `repeat-drafting.json` records a fresh model load and exact text matches for all three selected fundraiser conditions. This is a repeat of the same cases, not independent held-out evidence. Saved case hashes detect subsequent drift; they are not signed proof of original execution or preregistration.

## Corrections and interpretation limits

- The provided-facts drafting condition uses fictional test inputs. The prompt calls them verified, but no real organization or project was verified. Do not imply otherwise.
- Unsupported by the prompt does not prove a named organization does not exist. The issue is presenting specifics without a supplied basis or fictional-example label.
- Thinking examples use explicit positive/negative system instructions. The positive cases are induced agreement, not naturally occurring sycophancy. Show the instruction beside the example.
- The thinking plot is teacher-forced replay. Norms are not confidence, honesty, causal importance, or proof of reasoning faithfulness.
- Separate studies reuse some prompts and even produce identical responses. Do not pool their counts as independent trials.
- No independent judge, held-out confirmation study, statistical power analysis, or general safety improvement has been demonstrated.
- The historical adapter has unverified PEFT parity, an unspecified original training-base revision, a weak baseline, and unequal truncation. Do not publish it as reproduced emergent misalignment.
- Runners generally resume completed files rather than force new inference. The audit's separate rerun script avoids mistaking a cached completion check for replication.
- Most studies were executed through scripts using Dyno development components. Do not claim all were run entirely through the app UI. The saved native render is a development visualization, not proof of a point-and-click generation run.

## Primary references checked

- [Persona vectors and original scope](https://www.anthropic.com/research/persona-vectors)
- [Pinned persona-vector source](https://github.com/safety-research/persona_vectors/tree/b8e0f044fe2410a6fad579f38324f03f13b4e917)
- [Reasoning faithfulness](https://www.anthropic.com/research/reasoning-models-dont-say-think): contextual motivation, not replicated here.
- [Refusal-direction authors' code](https://github.com/andyrdt/refusal_direction): this behavioral screen is not its causal intervention experiment.
- [Open model organisms](https://github.com/clarifying-EM/model-organisms-for-EM): historical port remains held.
- [Actual model repository](https://huggingface.co/lmstudio-community/Qwen3.8-27B-MLX-4bit), pinned revision in each manifest.

## Before stronger claims

Freeze new tasks and analysis before running them; independently label behavior before inspecting representation scores; choose layer/strength on separate validation data; include input-only and random controls; retain incoherent/truncated outputs; test the final method on untouched examples. Preserve failures and report uncertainty. No causal claim should rest on norm plots alone.
