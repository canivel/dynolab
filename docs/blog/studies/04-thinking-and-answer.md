# Inside AI Models, Part 4: Does More Thinking Mean a Better Answer?

I wanted to see the model's thinking next to its answer. Then I wanted to put the measured activations beside both.

The second wish is where the labels start to matter. Generated thinking is text. Activations are numerical states. Showing them together does not magically turn either one into an explanation of the other.

## Six prompts, two modes

I took six cases from the persona-vector pilot and ran each with thinking disabled and enabled. Four cases were two questions under contrasting instructions; two were neutral evaluation questions. The model and question stayed fixed within each pair. The chat template changed to enable or disable thinking.

This used the same pinned Qwen3.8-27B four-bit MLX checkpoint, greedy generation, and a 768-token cap in both modes. All twelve responses finished, and all six thinking-on responses contained a completed thinking section followed by an answer.

Across the six cases, thinking-off generated 340 tokens. Thinking-on generated 1,101, including its reasoning text. Those are counts from this run, not a general speed or intelligence benchmark.

## The instruction did not disappear

In the two agreement-inducing cases, the system instruction explicitly prioritized pleasing the user, even at the expense of factual accuracy. Thinking-on still produced strong agreement. That is evidence about these deliberately instructed cases, not a measurement of spontaneous sycophancy.

One thinking section restated that agreement instruction. It is tempting to read that as a transparent description of the model's internal process. I am treating it as another recorded output. Anthropic's research on reasoning faithfulness is a useful reason to keep that distinction visible; this experiment did not reproduce its hint-based tests.

The negative-instruction and neutral cases included qualifications. There is no broad safety conclusion hiding in this little comparison. Thinking did not automatically override the agreement-inducing setup, but that is not the same as showing that thinking is generally ineffective.

## What the viewer actually shows

The development version of Dyno Lab can import these saved artifacts into Lab → Research artifacts. It separates model-emitted thinking from the final answer and lets me filter prompt, thinking, and answer tokens.

The activation plot comes from a fresh forward pass over the recorded prompt and response, called teacher-forced replay. It is not a live trace captured during the original generation. Its block-output norms measure magnitude, not confidence, honesty, or safety. Selecting a token lets me inspect the underlying number without pretending it explains a decision.

There is also a mundane but important check: if the thinking section never closes, the parser must not present the remainder as a completed answer. The development tests cover that case.

## Why I wanted this view

Dyno Lab is an open-source Mac workbench I am building, with help from Fable and Astra, so I can learn from model behavior and numerical measurements in the same place. The viewer gives me a better way to ask questions. A faithful causal account will take additional experiments.

For this run, the useful observation is simple: more generated reasoning text did not erase the induced agreement. The useful tool improvement is being able to inspect the evidence while keeping its different parts clearly labeled.

## Explore the work

[Read the saved evidence](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/thinking-comparison) and its limitations. These are development research notes; the released app may not include the new viewer yet.

[Dyno Lab](https://dynolab.dev/) · [Documentation](https://dynolab.dev/guide.html) · [Source code](https://github.com/canivel/dynolab) · [Windows worker](https://github.com/canivel/dynolab-windows-client)

[Research or walkthrough referenced in this post](https://www.anthropic.com/research/reasoning-models-dont-say-think). Follow Inside AI Models on [Medium](https://canivel.medium.com/) or [Substack](https://canivel.substack.com/), whichever you prefer.

These experiments and drafts were prepared with AI assistance. The measurements are saved model runs; the qualitative review is model-assisted, not an independent scientific review.
