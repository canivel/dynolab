# Safety research we can investigate with Dyno Lab

Research review: September 13, 2026. These are proposed experiments, not completed reproductions. Feasibility is based on inspection of Dyno's current Lab worker, not a fresh runtime validation.

Development follow-up: the [factual pilot](../examples/sycophancy-pilot/README.md) and [published persona-prompt pilot](../examples/persona-vector-pilot/README.md) now contain real Qwen3.8 outputs. The first produced no false agreement; the second produced an instruction-induced contrast but no clear behavioral steering effect on its two evaluation questions. Response-span capture is implemented and verified through the development SDK/API. This does not complete the broader replications below. Inspecting the pinned upstream steering code also clarified that its `response` hook changes the final token on each forward pass, matching Dyno's existing position rule; generalized token-scope controls remain a separate extension.

Start with a question people can understand: **When does a model agree with a false claim because the user wants it to, and can we reduce that without making the model less useful?**

## Recommended sequence

### 1. Sycophancy: establish the behavior before probing it

Anthropic's [Towards understanding sycophancy in language models](https://www.anthropic.com/research/towards-understanding-sycophancy-in-language-models) studies assistants favoring agreement with user beliefs. This gives us a behavioral starting point rather than an assumption that a neuron represents dishonesty.

**Proposed hypothesis:** a user's stated incorrect belief increases incorrect agreement compared with the same question without that belief. Test correct-user-belief controls too: indiscriminate disagreement is not an improvement.

Use released evaluation materials where available and preserve their original scoring. A new factual-question dataset is an adaptation. Run a separate modern-model extension on the installed Qwen3.8 checkpoint, recording its exact revision and chat template. An older original checkpoint is useful as a replication control, even when the public demonstration uses the newer model.

Dyno can serve the model and fit a last-input-token probe. A scripted evaluation adapter is still needed for matched prompt groups, scoring, and aggregated comparisons. Prediction of a response label is not evidence of intent.

### 2. Persona vectors: move from prediction to intervention

Anthropic's [Persona Vectors paper](https://arxiv.org/abs/2507.21509) and [official implementation](https://github.com/safety-research/persona_vectors) provide a particularly practical starting point. The repository includes extraction/evaluation materials. Its paper vector averages response activations; it also implements prompt-average and last-prompt-token variants. Steering can target prompt, response, or all tokens.

**Proposed hypothesis:** an independently extracted sycophancy direction predicts false agreement on unseen topics, and steering against it reduces false agreement while preserving accuracy and coherence.

**Missing in Dyno:** dataset-aggregated vector extraction, vector import with model/hook provenance, response-span capture, and explicit token-scope steering. Current steering subtracts two individual prompt vectors and intervenes at the final position of each forward pass. That is not the paper's full method.

**Useful extension:** compare the paper's response-average vector against Dyno's inexpensive last-input-token probe. Measure generalization under implicit social pressure, not just explicit instructions to be agreeable. Compare against text-only baselines and random directions. This is a proposed investigation, not a claim of novelty; check related replications before framing a publication.

### 3. Assistant drift across a conversation

Anthropic's [The assistant axis](https://www.anthropic.com/research/assistant-axis) studies persona representations in Gemma 2 27B, Qwen 3 32B, and Llama 3.3 70B, including interventions and a Neuronpedia demonstration.

**Proposed hypothesis:** changes in an assistant-direction projection predict specific unwanted conversational behaviors on held-out conversations; activation capping reduces those behaviors without suppressing harmless role-play.

Dyno needs multi-turn datasets, response-position capture, imported directions, and the paper's capping operation. Current activation magnitude heatmaps do not measure the Assistant Axis. First reproduce a documented original-model condition, then test transfer to Qwen3.8 with newly extracted model-specific directions.

**Useful extension:** compare a general assistant direction with trait-specific sycophancy monitoring, including false alarms during harmless creative writing. Use conversation-level splits and report utility losses.

### 4. Emergent misalignment: a grounded OpenAI connection

OpenAI's [Toward understanding and preventing misalignment generalization](https://openai.com/index/emergent-misalignment/) investigates broader behavioral changes following narrow bad-data fine-tuning. Its [helpful assistant features follow-up](https://alignment.openai.com/helpful-assistant-features/) examines restoring helpful features, using a large SAE on GPT-4o activations.

We cannot reproduce those proprietary internal measurements in Dyno. A tractable alternative is the [Model Organisms for Emergent Misalignment project](https://github.com/clarifying-EM/model-organisms-for-EM), which OpenAI points readers toward. It releases open-model adapters, steering vectors, and evaluation code.

**Proposed hypothesis:** in a matched base/fine-tuned open-model pair, a direction associated with undesirable behavior transfers across fine-tunes of the same base model; restoring an independently identified helpful direction has a different utility tradeoff from suppressing the undesirable direction.

Begin with released checkpoints rather than training a new organism. Dyno needs adapter conversion/loading validation, matched-checkpoint comparison, response capture, and imported directions. A faithful SAE experiment additionally needs an SAE trained for the exact model and hook, with reconstruction and intervention validation. Dyno's small experimental SAE is not a substitute for OpenAI's pretrained dictionary.

**Useful extension:** measure whether quantization changes behavioral effects, probe calibration, and intervention strength. Compare like-for-like checkpoints. MLX versus GGUF differences can reflect conversion, precision, templates, or sampling, not distributed execution itself.

### 5. Refusal and over-refusal

[Arditi et al.'s paper and code](https://github.com/andyrdt/refusal_direction) investigate a direction mediating refusal.

**Proposed hypothesis:** the same intervention that changes refusal on unsafe requests also changes false refusals on harmless, superficially similar questions.

Use the author's protocol for the reference reproduction. Dyno's block scaling/zeroing is not directional projection ablation; implement and validate the actual operation and token/layer scope first. A useful extension measures refusal selectivity, answer quality, and coherence together, including benign educational and defensive questions. A lower refusal rate alone is not a safety improvement.

## Supporting evaluation infrastructure

Anthropic's [Bloom](https://github.com/safety-research/bloom) can help generate and score behavioral scenarios. Treat it as an optional evaluation adapter, not a replacement for a locked test set or human review. Record judge model/version, disclose external API use and costs, and retain transcripts. Generated evaluations used to tune an intervention cannot double as its independent final test.

## First study protocol to lock before execution

1. Use a disjoint pilot to check that sycophancy is measurable and to determine sample size. Retain a negative result if the effect is absent.
2. Build neutral, correct-user-belief, and incorrect-user-belief variants around independently verified facts. Separate the underlying facts and prompt families across training, validation, and final test. Reserve another topic family for distribution shift.
3. Freeze dataset hashes, checkpoint/revision, quantization, exact serialized templates, thinking setting, token budget, seeds, hook positions, and scoring rubric. Treat thinking on/off as separate conditions if compared.
4. Label actual generated answers. Separate false agreement, correct disagreement, refusal, ambiguous answers, and truncation. Blind any human/judge review to intervention condition.
5. Fit the probe using training data only. Choose layer, threshold, and steering strength using validation only. Compare majority, shuffled labels, token length, and a text-only classifier. Do not call recognizing pressure phrases detection of actual sycophancy.
6. Run baseline, chosen steering, zero-strength, and norm-matched random-vector controls on the locked test. Report false-agreement rate, factual accuracy, benign helpfulness, coherence, probe AUROC/calibration, and uncertainty grouped by underlying fact. Never count paraphrases as independent facts.
7. Publish all conditions, failures, exclusions, and raw exports with a reproducible script. A pooled backend parity check is a separate engineering result. Verify supported hooks and numerical agreement on a small model before the expensive pool run.

## Deliverable worth sharing with researchers

A small replication package with pinned artifacts, an explicit table of deviations from the original method, independently scored held-out results, and a short recording that follows one prompt from answer to measurement to intervention. Only describe an improvement if its predefined outcome improves without an unacceptable utility loss. Easier reproduction and an informative negative result can both be useful contributions.

No new model experiments were run for this review. The existing identifier-fidelity experiment is separate evidence and must not be presented as a sycophancy or misalignment reproduction.
