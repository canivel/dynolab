# Research workflows: local development and review plan

Status: local implementation in progress, not a released feature set. No release/tag/version bump, production deployment, public study, or website push is authorized by this plan. Existing unpublished work is preserved. Research motivation and source review: local `dynolab-local-research/roadmaps/2026-09-16-alignment-forum-feature-review.md`.

## Shared requirements

- Use a versioned study manifest across the native app, SDK, HTTP and MCP. Keep exploratory notebook entries intact; controlled experiments are an associated artifact with immutable protocol revisions.
- Separate protocol, attempted runs, labels, metrics and interpretations. Every aggregate links to its denominator and contributing run IDs. Invalid, cancelled, truncated and ungraded runs are explicit, never silently counted as passes.
- Pin model identifier/revision when known, backend, quantization, template, generation settings, dataset hash and grader revision. Mark unavailable metadata as unknown. Seeds do not guarantee cross-device numerical identity.
- Data stays local by default. Export/import is data-only with bounds, schema checks and content hashes. Hashes detect modification but do not establish author identity or truth.
- Keep read/prepare separate from execute/publish. Endpoint selection is explicit. No arbitrary URLs, paths, code or shell commands supplied by imported studies may execute automatically.
- Local build must not overwrite the installed release. Review website changes through localhost. Never use fabricated screenshots as research evidence.

## 1. Controlled studies and response comparison

### Deliverables

1. Protocol editor: question, hypothesis, scoring rubric, named conditions, paired case IDs, development/test split, seeds/repeats, token budget, thinking option and explicit running endpoint.
2. Validate and freeze protocol before execution; edits create a new revision/study. Preflight shows planned request count and maximum output-token budget.
3. Bounded serial runner reuses served models; persists each attempt before/after request; cancellation stops scheduling and discloses that in-flight server work may continue. Restart marks abandoned work interrupted. Resume never overwrites a previous attempt.
4. Native progress, saved history and side-by-side condition outputs, with raw request/response and finish reason. Match results by case and seed, not array index.
5. Manual labels with rubric/reviewer/version, blind review that conceals condition/model where feasible, explicit unblinding and disagreements.
6. Report per-condition counts, paired differences and task-level uncertainty; development and held-out results cannot be silently pooled. Keep descriptive/exploratory status visible.

### Tests and acceptance

Validation rejects duplicate IDs, malformed splits, unreasonable sizes and invalid ports. Mock endpoint checks request settings and durable records. Cover timeout, malformed response, token exhaustion, cancellation races, restart/resume and endpoint disappearance. Hold-out cases cannot be altered in place. Live small-model test must save and reopen paired outputs. UI must expose all failures without truncating their meaning. Screenshot protocol, progress and comparison from that live test; caption sample size and exploratory status.

## 2. Human review and monitor evaluation

### Deliverables

1. Explicit target and monitor identities; configurable answer-only, thinking-only, action-only or combined views. Never silently substitute provider summaries for raw thinking.
2. Preserve human reference labels separately from monitor predictions. Unknown reference labels are excluded with a visible count.
3. Fix thresholds using development data; evaluate on held-out tasks. Show confusion matrix, precision/recall, false-positive rate, missed examples, class counts and calibration where confidence scores exist.
4. Reviewer queue with disagreements, source evidence and label history. Independent task verifier outranks self-reported success only for the specific property it actually tests.
5. SDK/API/MCP request and result formats shared with UI; monitor budget visible before execution.

### Tests and acceptance

Hand-calculated metric fixtures including empty classes, all-negative predictions and incomplete labels. Verify view restrictions omit hidden fields, and prompt injection inside model output cannot change grader configuration or call tools. No threshold tuning on held-out labels. Live demonstration compares at least two views without claiming statistical significance from a tiny sample. Screenshot confusion matrix and disagreement evidence.

## 3. Probe/intervention validation and regression reports

### Deliverables

1. Dataset group IDs, immutable train/validation/test partition and leakage checks. Layer/hyperparameter choice uses validation only.
2. Probe controls: shuffled labels, constant/simple behavioral baselines, calibration and cross-domain tests. Store training inputs/normalization and artifact hashes.
3. Intervention controls: no-op, restored baseline, donor/target and magnitude-matched random directions. Repeated seeds and paired inputs.
4. Regression report: target behavior, ordinary task correctness, refusal, honesty and monitor detectability, with per-metric denominators and uncertainty.
5. Strict compatibility matrix: model revision, architecture, quantization, tokenizer, hook name, dimension and normalization. Reject unsupported combinations. Preserve existing bounded pool hooks; do not imply gradients or arbitrary hooks are available.
6. J/R-lens and external SAE/circuit adapters only after independent upstream parity tests; artifacts remain descriptive until causal validation exists.

### Tests and acceptance

Reject leakage and incompatible artifacts; null-label baselines should not claim discoveries. Identity intervention/restoration matches within documented backend-specific tolerances. Check pool vs single-device drift without asserting universal parity. Run one small supported model with all controls; save negative results too. Screenshots show controls and task outcomes together. Gradient-based integrations are gated until backend support and parity actually pass.

## 4. Reproduction and community review

### Deliverables

1. Export manifests, anonymized prompts as reviewed by the author, results, labels, limitations, licenses and source credit; review redaction before sharing.
2. Reproduction bundle import is bounded and data-only; validate schema/hash and do not execute or publish. Parent content hash identifies exact source version.
3. Native prepare-reproduction flow: select compatible endpoint, inspect differences and expected tolerance, explicitly run, then produce comparison report.
4. Research-site states: original finding, attempted reproduction, reproduced within stated tolerance, conflicting and inconclusive. Evidence attachments required for outcome claims. Upvotes remain separate.
5. Permission/ownership checks, revision audit trail and rate/body limits for HTTP, SDK and MCP. Agents cannot promote their own unsupported result to verified truth.

### Tests and acceptance

Round-trip export/import; corrupted/oversize bundles; cross-user writes; missing artifacts; malformed parent IDs; duplicate submissions; unknown fields; imported executable payloads. Run against local research website and isolated local database only. Screenshot local export, import, comparison and local reproduction page. No writes to production Neon or public forum during testing.

## 5. Isolated agent tasks and training comparisons

### Deliverables

1. Start with deterministic simulated tools/tasks, then a separately designed OS/container sandbox. No host shell/network/credentials exposed through the experiment protocol.
2. Verifier and append-only trace store outside model-writable workspace. Record tool inputs/outputs, environment snapshots and verifier outcomes independently from final claims.
3. First scenario: broken test runner. Score whether the final answer accurately discloses inability to verify; distinguish this from correctness of the proposed fix.
4. Budgets: tool calls, tokens, duration, files and output size; cancellation and cleanup. Run capability-limited tools, not unrestricted agent code imported from a study.
5. Checkpoint/adapter comparison with dataset lineage and unseen regression suite. Training itself is a separate future backend until supported; inference pooling is not distributed training.

### Tests and acceptance

Path escape, symlink, network and secret-access attempts must fail before real-code sandbox is exposed. Synthetic tool outputs cannot modify verifier outcomes. Cancelled task leaves no workers running. A small live model uses only simulated tools; outputs and actual outcomes are both recorded. Training comparisons may use existing independently produced checkpoints, clearly labeled; do not claim a training pipeline until implemented and tested.

## Documentation, review and release gates

For every implemented slice: update app guide, API schema, SDK/MCP docs and limitations together. Add source links and exact reproduction commands. Run targeted tests before live inference. Build native UI and inspect rendered screenshots. Rebuild the local preview only after successful checks.

Website: local feature walkthrough with real screenshots, evidence links and compatibility limits; mark development-only features as preview. Keep the published website unchanged. Use a local feature matrix showing implemented/tested/planned, not marketing claims for unfinished work.

Final review package: source diff, test logs, live study manifest/results, screenshots, local app path and website URL, known limitations and any blocked gates. User reviews before any push, release, deployment or public study publication.

## Implementation order and status

| Work package | Dependency | Current status |
|---|---|---|
| Protocol storage + serial runner | Existing local inference endpoint | Initial implementation; unit/HTTP and four-request live acceptance passed |
| SDK/API/MCP controlled-study access | Protocol validation | Implemented locally; SDK round-trip and MCP tool-list tests pass |
| Native protocol/comparison UI | Runner API | Builds; native dark/light screenshots reviewed against saved live results |
| Human labels + monitor metrics | Immutable run records | Context-masked review and bounded monitor execution tested; real answer/thinking checks passed; development-only selection and a small held-out software acceptance run completed |
| Probe/intervention validation | Grouped datasets + backend capabilities | Grouped probe selection, baseline controls and intervention controls passed local 27B checks; paired regression reports and metadata compatibility checks implemented; artifact application remains separate |
| Reproduction packages | Versioned results and labels | Data-only import/export, linked preparation and immutable-parent text comparison tested; artifact compatibility reports implemented |
| Research-site reproduction UI | Local database/auth isolation | Implemented locally; isolated database permissions and native page rendering checked; not deployed |
| Simulated agent task | Independent outcome record | Bounded virtual workspace, independent verifier and live 27B acceptance completed |
| Real-code sandbox and training backend | Separate security/backend validation | Gated |
| Live examples, screenshots and documentation | Each corresponding feature passes | Pending |

These statuses must be updated from actual evidence as work proceeds. Completing this plan is not equivalent to implementing it.

## Local checkpoint: 2026-09-16

Python unittest suite: 120 tests, 6 skipped for optional dependencies. Native release build passes using Command Line Tools. Four real generation requests completed on the downloaded 27B model. They test software behavior and are not new scientific evidence. See [controlled studies](../controlled-studies.md) for the implemented API and limits.

Not yet implemented: automatic model revision checks, paired uncertainty estimates, full monitor workflow, additional probe/intervention controls, local community reproduction pages, simulated agent tasks, and training comparisons. None of those should be described as available or tested.


## Human-review checkpoint: 2026-09-16

Stage A of [human review and monitor evaluation](human-review-monitor-evaluation.md) is implemented locally. The full Python suite passes 125 tests (6 optional-dependency skips), including SDK/HTTP and stdio MCP review round trips; native release build passes. Native UI was exercised against saved real responses with no running model, under an automated acceptance reviewer with prior exposure declared. Monitor execution, held-out threshold enforcement and the comparison report remain planned; this checkpoint does not complete work package 2.

## Monitor and probe checkpoint: 2026-09-16

Bounded answer/thinking/combined monitor evaluations are implemented in the native UI, SDK, HTTP and MCP. Answer-only and thinking-only live evaluations completed on two saved 27B responses. Both references were automated acceptance judgments marked pass: recall is unavailable, and this is not an independent scientific evaluation. Group leakage and evidence restriction tests pass.

Grouped linear probes now fit normalization on training data and select layer/regularization on validation Brier score. A 12-example live negation fixture completed on the 27B model, with majority, shuffled-label and text-length controls. No-op, restored baseline and three random-direction intervention controls also completed. A live check caught and corrected dtype promotion in the random control. The corrected identity and restoration checks had zero observed drift.

Reproduction reports freeze parent evidence and match by case/condition/seed. Exact text agreement is not a semantic reproduction verdict. Community reproduction pages, independent agent-task verifiers, paired uncertainty estimates, complete behavioral regressions and automatic artifact compatibility remain unfinished. Real-code sandboxing, upstream adapter parity and training remain gated.

Local acceptance data: `dynolab-local-research/monitor-acceptance`. No production changes or release.

Validation for this checkpoint: 139 Python tests ran successfully with 8 optional-dependency skips; the four numerical probe tests also passed under the bundled runtime. Native release build and generated documentation checks passed. Monitor and probe screenshots were inspected. The preview app was rebuilt separately from the installed release and reopened; the monitor screen was reached through Studies → Controlled comparisons. Inference used for acceptance was stopped after testing.

## Completion checkpoint: 2026-09-17

The historical checkpoints above describe earlier states. The six follow-up implementations and current limits are recorded in [research completion](research-completion.md). All work remains local for review.
