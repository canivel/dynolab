# Inside AI Models, Part 1: How Can We Understand Their Behavior?

*A hands-on journey into AI interpretability and safety, one experiment at a time.*

I can run a model on my computer, ask it a question, and get a surprisingly good answer.

Then I change a few words and get a completely different answer. Sometimes a confidently wrong one. That leaves me with a question I keep coming back to: what changed inside the model?

Asking it to explain its answer can be useful, but that explanation is another generated response. To investigate the computation itself, I need a different kind of evidence.

That is what drew me toward interpretability: studying the internal computations of a model to better understand its behavior. I wanted to turn what I was reading into experiments I could run, visualize, and learn from. My hope is that sharing that process helps others explore these questions too.

## From reading about models to experimenting with them

My interest is AI safety and alignment. I want to understand how we can detect failures, investigate what causes them, and evaluate whether a proposed improvement actually helps.

There is a lot of valuable research to learn from. For me, a method becomes much easier to understand when I can connect it to a specific input, a measurement, and a result I can inspect.

When I read about activations, probes, and interventions, I start thinking about experiments. Can an internal signal help predict a mistake? If I change that signal, does the answer change? Will the result hold when I try different examples?

I wanted a visual workbench for that process on my Mac: run a model, try a focused experiment, compare the results, and save enough information to revisit it later.

So I built [Dyno Lab](https://dynolab.dev/), with help from Fable and Astra :)

Building the tool has become part of the learning. Deciding what a chart should show means deciding what I’m actually measuring. Deciding what to save means thinking about what someone else would need to reproduce the experiment. Those choices have been useful questions in their own right.

![A real Qwen3.8 identifier-fidelity probe in Dyno Lab](https://dynolab.dev/assets/identifier-probe-results.png)

*A real Qwen3.8-27B MLX experiment. The probe predicts whether a reference will be preserved in the answer. The chart includes training and test examples; evaluation uses only the test split.*

## Different methods answer different questions

An activation is a numerical value computed inside a neural network as it processes an input. Looking at activations gives us something to measure, but connecting those measurements to behavior takes further experiments.

A **probe** is a small model trained to predict a label from another model’s activations. For example, we can ask whether a selected representation contains information that helps distinguish correct answers from incorrect ones. A successful probe shows that the information can be read out. Establishing whether the original model uses it requires additional evidence.

An **intervention** changes part of the computation and measures the effect. We might replace an activation from one input with an activation from another, then compare the outputs. Carefully chosen controls help distinguish a specific effect from general disruption to the model.

A **sparse autoencoder** learns a representation in which relatively few features activate for a given input. That can help us explore recurring patterns. Interpreting a feature means examining examples, looking for counterexamples, and testing whether its apparent meaning holds up.

These methods give us different ways to investigate the same model. I’m interested in how their results fit together, and where they disagree. That seems like a productive place to learn.

The model and the software used to run it also matter. I’m documenting supported experiments and implementation limits in the [guide](https://dynolab.dev/guide.html), so the setup can be inspected alongside the result.

## A reference number, a wrong answer, and a confident explanation

Here is a small behavior that made me stop and look more closely.

I asked Qwen3.8-27B to copy a reference. In one test, it called the supplied string a prompt injection. With different wording, the same string became an entirely different reference in otherwise valid JSON.

The string was `tarskereso`. It was being used as a fictional inventory label. There was no instruction hidden in the prompt asking the model to break its rules.

An ordinary reference worked. Writing the unusual reference as space-separated letters worked too. The inventory department would probably prefer that the model keep the original label. I would also like to know why it lost it.

This behavior came from a [public Qwen3.8 report with reproduction scripts](https://ingot.tools/reports/qwen3-8-27b-glitch-tokens). The broader problem has an established research history: [Fishing for Magikarp](https://aclanthology.org/2024.emnlp-main.649/) studies undertrained tokens and how to detect them. The newer Qwen report is a community investigation, not a peer-reviewed safety assessment.

I reproduced selected failures locally, using a pinned four-bit MLX model with thinking disabled. That matters: my setup is different from the source report's runtime and precision. The exact answers varied with the task. Identifier corruption was the more consistent observation; the model's explanation for it was not.

That distinction is the reason to look inside. A fluent safety explanation does not establish what caused the behavior. It gives us another output to investigate.

## Can an internal measurement help predict the failure?

I built a small follow-up experiment in Dyno Lab: 12 reported identifiers, each paired with an ordinary reference, in three task wordings. That produced 72 real answers. Eight identifier groups trained a logistic probe; four different groups were held out, giving 48 training examples and 24 test examples.

The label is deliberately narrow. A failure means the literal reference is absent from the answer. It does not mean the answer is harmful, dishonest, or even a refusal. The probe reads layer 32's final input-token activation before generation. The answer itself is never part of its input.

On those 24 test examples, the probe caught all 7 missing-reference outcomes and raised 2 false alarms: 91.7% accuracy, with AUROC 0.975. Always predicting preservation reached 70.8%. A simple baseline using only input token count reached 87.5%, so there is a real shortcut to take seriously. One training response hit the output limit and was retained; none of the test responses was truncated. These are measurements from one fixed split, not a general reliability estimate.

Both false alarms involved `webElementX`: the model copied it correctly, but the probe flagged it. Those examples belong in the walkthrough just as much as the failures it caught.

This is a small exploratory experiment. Earlier screening influenced which strings I chose, and the ordinary references have a distinctive format. Holding identifiers out prevents one kind of memorization, but does not remove every shortcut. The next useful test would bring in new identifiers, more realistic document contexts, and stronger input-only baselines.

The [walkthrough includes the actual Lab recording, settings, every answer, probe weights, and results](https://dynolab.dev/probe-example.html). It also preserves the less exciting part of the search: the earlier prompt-injection successes from another report did not reproduce in my local test.

For me, this is a useful starting point for safety research. A model can reject something harmless or quietly alter a record, and its explanation can be misleading. We can make that behavior visible, measure a specific outcome, and test competing explanations. A probe score is one piece of that work. Establishing the mechanism would require further experiments, including controlled interventions.

## Studying larger models with the hardware at home

Once I started thinking about larger experiments, another practical question came up.

I have a Mac with 128 GB of unified memory and a desktop with an RTX 5090. Could they work together to load a model that didn’t fit comfortably on either device alone?

They could. The gaming PC had found another occupation.

![A real larger-model pool running across a Mac and an RTX 5090](https://dynolab.dev/assets/pool-235b-live.png)

*Qwen3-235B-A22B Q4_K_M running in a local pool. The model file is 142.2 GB. The displayed headroom is a pre-load snapshot, not reserved capacity, and the two GPU utilization measurements have different meanings.*

Using an experimental GGUF runtime, we ran the 142.2 GB Qwen3-235B-A22B Q4_K_M model across the Mac and the Windows worker and generated real responses. Parts of one model run on the different devices, connected through the local network.

That expands the models I can experiment with, while introducing tradeoffs worth measuring. Network speed, loading time, and how the model is divided across devices all affect the experience. CPU output tensors also participated in this run. Each model still needs a capacity check, and pooling does not guarantee a speed improvement.

I added this capability to the workbench, along with local-network model serving. They serve different purposes: sharing an endpoint lets another computer send requests to a running model; pooling distributes the work of running one model across devices.

I’ll explore the setup and measurements in a later post. For now, it has opened up a useful direction for doing more with hardware I already own.

## Making the work useful to other people

The app, SDK, APIs, and Windows worker are open source. I’m also sharing example data, settings, and results so others can inspect the work, reproduce an experiment, or take it in a different direction.

- [App, SDK, and APIs](https://github.com/canivel/dynolab)
- [Windows GPU worker](https://github.com/canivel/dynolab-windows-client)
- [Documentation and examples](https://dynolab.dev/guide.html)

Working with Fable and Astra has helped me turn ideas into something I can test. I’m keeping the code and measurements open to review because feedback can improve both the tool and the experiments built with it.

I hope this makes the work easier to approach for someone starting out and useful to people already exploring these methods. A correction, a stronger control, or a different explanation for a result can move the work forward.

Over time, I want to contribute to practical questions in AI safety and alignment. Building a clearer understanding of model behavior, through experiments others can inspect, is the direction I’m taking.

## What we’ll explore next

This series will follow a connected set of questions. First, what can we observe inside a model as it processes a prompt? Then, can those signals help predict mistakes, and can interventions help us investigate their causes? From there, we’ll explore recurring features, studying larger models on home hardware, and making experiments reproducible.

Each post will include a concrete question, the method, the results, and what I think is worth testing next. I’ll use the tools I’m building and keep the focus on what the experiments teach us.

What is one AI behavior you would like to investigate more closely? If you already work with these methods, what experiment would you recommend as a useful starting point?

I’d enjoy comparing notes. If you run the example, an issue on GitHub with your model, settings, and observations would be especially useful. If the project is useful to you, consider giving it a star.

You can [explore the experiments](https://dynolab.dev/probe-example.html), [look through the code](https://github.com/canivel/dynolab), or follow the series on [Substack](https://canivel.substack.com/).
