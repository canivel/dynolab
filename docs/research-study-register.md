# Safety study register

Development results, not released capability guarantees. We preserve every run, including negative results. Small adaptations are not full paper replications. Model-assisted qualitative review is unblinded unless explicitly stated otherwise.

| Study | Recorded outcome | Interpretation / next gate |
| --- | --- | --- |
| Factual pressure | 36/36 choices correct; no induced flips | Useful negative result; no positive labels for a sycophancy probe |
| Persona vector | Four induced contrasts; no clear steering effect on two evaluation questions; zero controls match | Pipeline check, not successful behavioral control; needs held-out validation and strength selection on separate data |
| Thinking comparison | Six matched pairs, all complete; 340 off versus 1,101 on generated tokens | Thinking text and replay viewer work; no general safety or speed conclusion |
| Refusal selectivity | Six wrongdoing refusals and six benign assistance responses | Small behavioral screen; no causal refusal-direction test |
| Unsupported drafting details | Two clear, one ambiguous, one information-request outcome in four underspecified tasks; eight controls without those specifics | Exploratory teaching example; needs independent review and untouched tasks |
| Historical emergent-misalignment adapter | Sixteen base/adapter outputs retained, including caps | Runtime feasibility only; PEFT parity and original evaluation protocol still required |
| Assistant Axis | Source and compatibility audit only | No compatible validated Qwen3.8 axis; do not import another model's vector or claim completion |

Evidence is under `examples/sycophancy-pilot`, `persona-vector-pilot`, `thinking-comparison`, `refusal-selectivity`, `unsupported-details`, and `emergent-misalignment-reference`. Each directory records its scope and available raw results. The older Qwen2.5 reference is for an author-released adapter, not the product demonstration model.

## Publication gates

Publish useful observations with raw cases, controls, model revisions, stopping conditions, and failed outcomes. Before a general improvement claim, require an independently reviewed rubric, held-out prompts, a baseline and appropriate controls, uncertainty estimates, and a repeat run. Do not select only favorable examples. Hypothesis exploration and confirmation must be labeled separately.

## Generated thinking in the development app

Lab → Research artifacts imports `kind: generation` JSON from the thinking comparison. It separates model-emitted thinking from final answers and lets users inspect token phases and measured block-output norms. The measurements are teacher-forced replay, not a live trace or a causal explanation. A missing thinking terminator cannot be treated as a completed final answer. Imported artifacts use the existing local archive.

The SDK's development `lab.capture_response` captures prompt-last, prompt-mean, and response-mean representations from a fresh replay. It does not prove that a text explanation faithfully describes model computation. See the SDK/API development notes.
