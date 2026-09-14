# Inside AI Models, Part 5: An AI Can Refuse a Scam and Still Invent a Budget

The model refused to help write a fake charity appeal. Good.

Then, asked for an accurate appeal for a real community project, it confidently supplied a community center, a wheelchair ramp, and a $15,000 budget. I had provided none of those details.

A refusal check and an accuracy check were asking different questions. My small experiment made that distinction quite tangible.

## Similar topics, different requests

I wrote six pairs of prompts. Each pair shared a topic but changed the requested action: a genuine security notice versus a deceptive one, legitimate account recovery versus unauthorized access, and other everyday contrasts involving repayment, citation, fundraising, and reviews.

This was a convenience screen of twelve prompts, not a jailbreak benchmark. I used the pinned Qwen3.8-27B four-bit MLX checkpoint with thinking disabled, greedy generation, and a 192-token cap. None of the responses reached that cap.

In an unblinded, model-assisted review, all six wrongdoing requests received explicit refusals without the requested wrongdoing instructions. All six benign requests received assistance. I did not score those benign answers as fully accurate; the fundraising example is exactly why that would have been a mistake.

## The answer I had not asked for

The benign fundraising response named the Elm Street Community Center and described a ramp costing $15,000. It also asserted where every donated dollar would go and said a detailed budget was available on request.

Those claims were unsupported by the prompt. I did not independently investigate whether some organization with that name exists. The problem is that the model presented those specifics as the requested factual appeal without a supplied basis, rather than asking for information or labeling a fictional example.

That is a narrow observation I can point to in a saved answer. It does not establish intent to deceive.

## What this does not reproduce

There is published work on a direction in activation space associated with refusal. I have linked the authors' code for readers interested in that causal question. This screen did not extract or ablate a refusal direction. Capturing a representation and seeing a refusal is not the same as demonstrating its mechanism.

Nor do six refusals establish general robustness. The prompts were direct, the topics limited, and the review was not independent. Their value was to check behavior and reveal a different issue worth following up.

## Following the evidence

The next experiment kept the drafting problem and changed the prompt conditions: unspecified details, explicit placeholders, and supplied facts. That follow-up was chosen because this case failed, so I call it exploratory rather than an untouched confirmation.

I am using Dyno Lab, the open-source Mac workbench I am building with help from Fable and Astra, to connect this kind of behavioral check with inspectable measurements. Some days the useful result is a graph. This time it was noticing that a helpful-sounding budget had no source.

I want both outcomes in the record: the refusals that worked in this small screen, and the benign response that still needed correction.

## Explore the work

[Read the saved evidence](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/refusal-selectivity) and its limitations. These are development research notes; the released app may not include the new viewer yet.

[Dyno Lab](https://dynolab.dev/) · [Documentation](https://dynolab.dev/guide.html) · [Source code](https://github.com/canivel/dynolab) · [Windows worker](https://github.com/canivel/dynolab-windows-client)

[Research or walkthrough referenced in this post](https://github.com/andyrdt/refusal_direction). Follow Inside AI Models on [Medium](https://canivel.medium.com/) or [Substack](https://canivel.substack.com/), whichever you prefer.

These experiments and drafts were prepared with AI assistance. The measurements are saved model runs; the qualitative review is model-assisted, not an independent scientific review.
