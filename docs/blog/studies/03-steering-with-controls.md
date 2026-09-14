# Inside AI Models, Part 3: Can Changing Activations Change an Answer?

Telling an AI to agree with you is easy. Finding a numerical change inside the model that makes it agree more reliably is another problem.

I tried a small adaptation of Anthropic's persona-vector workflow. I could elicit a clear contrast with instructions. I did not demonstrate useful behavioral steering at the settings I tested.

## From two kinds of answer to one direction

The published persona-vector materials include prompts intended to encourage and discourage a trait. I used the first four extraction questions and the first instruction pair, then added the same two-sentence limit to both conditions.

For one question about remote work, the agreement-inducing instruction produced “undeniably superior in every conceivable aspect.” The opposing instruction produced a qualified answer about roles, industries, and preferences. This was an induced contrast. It was not an accidental discovery that the model naturally holds either opinion.

Using Qwen3.8-27B in four-bit MLX, I replayed the saved prompt and answer, measured block 32, averaged response-token activations within each example, and averaged the positive-minus-negative differences across the four pairs. The resulting vector is a candidate direction. Its existence alone does not validate what it means.

## The controls were the point

I tried two separate evaluation questions with four conditions each: zero strength, a negative coefficient, a positive coefficient, and a random direction with the same L2 norm. The nonzero coefficients were -0.5 and +0.5. The intervention affected the final token of each forward pass, including prefill.

Both zero-strength outputs matched their unhooked baselines exactly. That is a useful implementation check. Across the other conditions, wording changed, but the two answers retained their basic positions. An unblinded qualitative review found no clear directional change in agreement.

There were eighteen saved responses in total: eight extraction answers, two evaluation baselines, and eight intervention answers. None reached the 160-token output limit.

## A direction is not a personality dial

This is a small adaptation of the research, with a different model, quantization, runtime, answer-length constraint, and evaluation scale. It does not refute the paper. It also does not reproduce its stronger claims.

I would need a larger extraction set, independently reviewed behavior labels, a separate validation set for layer and strength choices, and a final test I had not already inspected. A vocabulary change is not enough. Neither is a pretty activation plot.

That is why I saved the random controls and the zero controls alongside the interesting-looking examples. They make it harder to tell myself a convenient story.

## Making the experiment inspectable

Dyno Lab is the open-source Mac workbench I am building to run and visualize these experiments, with help from Fable and Astra. This pilot used scripts and measured replay data from its development code. It was not an end-to-end point-and-click paper reproduction.

I would still like a useful steering result. The first result is more modest: the candidate extraction and intervention pipeline runs, the zero controls agree, and this tiny evaluation did not establish the behavior change I was looking for. That is enough to decide what the next experiment needs.

## Explore the work

[Read the saved evidence](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/persona-vector-pilot) and its limitations. These are development research notes; the released app may not include the new viewer yet.

[Dyno Lab](https://dynolab.dev/) · [Documentation](https://dynolab.dev/guide.html) · [Source code](https://github.com/canivel/dynolab) · [Windows worker](https://github.com/canivel/dynolab-windows-client)

[Research or walkthrough referenced in this post](https://www.anthropic.com/research/persona-vectors). Follow Inside AI Models on [Medium](https://canivel.medium.com/) or [Substack](https://canivel.substack.com/), whichever you prefer.

These experiments and drafts were prepared with AI assistance. The measurements are saved model runs; the qualitative review is model-assisted, not an independent scientific review.
