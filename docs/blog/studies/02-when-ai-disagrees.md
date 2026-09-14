# Inside AI Models, Part 2: What If the AI Refuses to Agree With Me?

I started with a fairly ordinary question: can I make a model abandon a correct answer just by telling it I believe something else?

The plan was to find some examples of that behavior, then investigate the activations. The model had other plans. It answered every choice correctly.

That gave me a less dramatic article and a better experiment log.

## A small test of social pressure

I used twelve simple factual questions and asked each one three ways: without stating my belief, with a correct belief, and with an incorrect belief. That made 36 responses. The model was the pinned, four-bit MLX version of Qwen3.8-27B, running locally. Thinking was disabled, generation was greedy, and each answer had a 96-token limit.

The answer format was deliberately constrained. A strict parser read the A/B choice on the first line. That makes the scoring easier to audit, but it also makes this a very particular test. A short choice about a common fact is different from a long conversation about a person's identity, worries, or political views.

The result was 12 correct choices in each condition. There were no invalid choices, no outputs reaching the cap, and no correct-to-incorrect flips under the incorrect-belief condition.

## What I can actually conclude

This pressure template did not induce a wrong choice on these twelve facts. I cannot conclude that the model is immune to sycophancy, which is the tendency to accommodate a user at the expense of a better answer.

The questions were easy, selected by me, and used for exploration. They are not an untouched test set. There is also no sensible population-level safety percentage hiding inside 36/36.

The practical consequence was important: I did not train a detector using invented behavioral labels. Calling the pressured prompts “sycophantic” would have labeled my input condition, even though the model resisted it. A probe might learn to recognize that wording and still tell me nothing about a bad answer.

## Why this belongs in the series

I am building Dyno Lab because I want the steps between a question, a model response, and an activation measurement to be visible. It is an open-source Mac workbench for local inference and interpretability experiments, with an SDK and APIs. Fable and Astra have helped me build it and review these runs.

The research value here is a negative result and a decision about what not to measure yet. The next attempt uses published instructions that deliberately induce contrasting behavior. That is a different experiment, and it needs a different label.

Before claiming a detector works, I want actual examples of the behavior, independent labels, and new prompts kept out of development. For now, I have twelve facts that the model would not budge on. I am keeping them in the record.

## Explore the work

[Read the saved evidence](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/sycophancy-pilot) and its limitations. These are development research notes; the released app may not include the new viewer yet.

[Dyno Lab](https://dynolab.dev/) · [Documentation](https://dynolab.dev/guide.html) · [Source code](https://github.com/canivel/dynolab) · [Windows worker](https://github.com/canivel/dynolab-windows-client)

[Research or walkthrough referenced in this post](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/sycophancy-pilot). Follow Inside AI Models on [Medium](https://canivel.medium.com/) or [Substack](https://canivel.substack.com/), whichever you prefer.

These experiments and drafts were prepared with AI assistance. The measurements are saved model runs; the qualitative review is model-assisted, not an independent scientific review.
