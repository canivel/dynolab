# Inside AI Models, Part 6: Where Did That $15,000 Budget Come From?

The most concrete failure in my first set of safety experiments came from a fundraising request.

I asked for an accurate description of a real community project. Qwen3.8 supplied an Elm Street Community Center, a wheelchair ramp, and a $15,000 cost. A remarkably organized project, considering I had never described one.

I wanted to know whether giving the model clearer boundaries would change that answer.

## Three versions of the same task

I used four drafting tasks: a fundraising appeal, a nonprofit announcement, a donor impact update, and a community-garden grant update. Each had three conditions.

The first asked for factual copy without supplying the necessary details. The second added an instruction to use bracketed placeholders and not invent missing facts. The third supplied a small set of facts and required placeholders for anything else. The supplied facts were fictional test inputs, not independently verified facts about actual organizations, even though the prompt called them verified.

That made twelve responses from the pinned Qwen3.8-27B four-bit MLX checkpoint, with thinking disabled, greedy generation, and a 192-token cap. All responses finished within the cap.

## The awkward cases stay in

Two of the four underspecified requests produced clear unsupported details. Besides the fundraising budget, the garden update invented milestones, twenty raised beds, forty-five recruits, and budget progress.

One request received a sensible request for more information. Another explicitly disclaimed knowledge, then offered an illustrative example with numbers. I kept that last case separate as ambiguous. Counting it as an unqualified factual assertion would make the result sound stronger than the answer supports.

Across the eight placeholder and supplied-fact controls, the recorded review found no unsupported named, numeric, or dated specifics under that rubric. That does not mean every sentence was independently verified or that the templates were ready to publish. A placeholder is a request for missing information, not a fact.

## A useful result with a small boundary

This was a follow-up selected after seeing the earlier fundraising error. The review was unblinded and model-assisted. The tasks were all drafting tasks, and there were only four. I am not reporting a general hallucination rate, a novel discovery, or a proven safety fix.

I also cannot infer deception from a fabricated budget. The observable problem is unsupported specificity in the answer. Intent is another claim, and these data do not establish it.

What I can do is show the exact prompts, all twelve answers, and the review rubric. Someone else can disagree with a label without needing to reconstruct what I did.

## Before training a probe

It would be easy to label these conditions and train a classifier. It might then recognize words like “placeholders” instead of detecting an unsupported claim. I want new tasks, independently reviewed outputs, and input-only controls before claiming a useful probe.

Dyno Lab is the open-source Mac workbench I am building with help from Fable and Astra to make that process easier to run and understand. This study used its local model environment; it is a behavioral experiment, not yet an activation-based detector.

For now, the practical lesson is to inspect where the details came from. The model can write a convincing budget faster than I can verify one. That is precisely why I want the missing information to remain visible.

## Explore the work

[Read the saved evidence](https://github.com/canivel/dynolab/tree/codex/research-evidence-review/examples/unsupported-details) and its limitations. These are development research notes; the released app may not include the new viewer yet.

[Dyno Lab](https://dynolab.dev/) · [Documentation](https://dynolab.dev/guide.html) · [Source code](https://github.com/canivel/dynolab) · [Windows worker](https://github.com/canivel/dynolab-windows-client)

[Research or walkthrough referenced in this post](https://dynolab.dev/drafting-example.html). Follow Inside AI Models on [Medium](https://canivel.medium.com/) or [Substack](https://canivel.substack.com/), whichever you prefer.

These experiments and drafts were prepared with AI assistance. The measurements are saved model runs; the qualitative review is model-assisted, not an independent scientific review.
