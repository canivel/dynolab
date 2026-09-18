# Research feature completion plan

Local development and review only. Work in order. Each feature must have a documented data contract, failure behavior, native workflow, SDK/HTTP/MCP access where applicable, tests and a step-by-step guide. Do not equate passing software checks with a safety finding.

## 1. Behavioral regression reports

Freeze labeled controlled-study evidence for each named metric: target behavior, correctness, refusal, honesty, monitor detectability. Require an explicit baseline and comparison condition. Match case/seed pairs, exclude incomplete or disputed labels, report both directions of changes. Average within case groups before reporting an aggregate; bootstrap groups, never individual repeated samples. Show uncertainty as unavailable for one group. Preserve source hashes, rubrics and run IDs. UI creates and reopens reports without inference. Tests: hand-calculated improvements/regressions, uneven repeats, missing/disputed labels, cross-split separation, frozen history and API parity. Live acceptance uses saved actual responses; small samples remain exploratory.

## 2. Compatibility checks

Derive a versioned fingerprint from available model metadata and artifacts, not model name alone. Record revision, architecture, quantization, tokenizer/config hashes, hook, dimension and normalization. Compare with required fields, return compatible/mismatch/unknown, and block strict reuse unless all required values match. Check local artifacts with safe data parsing; no pickle or remote-code loading. Native report explains differences. Test unknown metadata, shape mismatch, tampering, name-only match and compatible contracts. Compatibility is technical eligibility, not scientific validity or cross-device numerical equivalence.

## 3. Monitor threshold selection

Create a new frozen evaluation from an existing evaluation's development predictions. Select a threshold using a declared objective and candidates; never inspect test labels when selecting. Preserve selection source/hash and evaluated candidates. Require a distinct held-out group, disclose prior test exposure, and do not claim an untouched test when test results were already used. Native flow previews selection and then explicitly starts held-out execution. Tests: changed test labels cannot alter selected threshold, empty classes, leakage, boundary/tie rules, and source mutation. Live check includes both reference classes; reviewer provenance remains explicit.

## 4. Community reproductions

Inspect existing forum implementation first. Add typed parent relation and evidence-backed author-reported outcome (attempted/supporting/conflicting/inconclusive), with original source hash and tolerance description. A vote is not evidence and an outcome is not independent verification. Validate import links, attachment ownership, auth scopes and immutability/audit behavior. Test against isolated local DB only, including cross-user writes and missing evidence. UI guides author and reader; never publish acceptance fixtures to production.

## 5. Simulated agent tasks

Implement a deterministic in-memory broken-test-runner task with allowlisted read/edit/test/finish actions. No actual filesystem, shell, network, package installation or credentials exposed to the model. Store each action, observation and an independent verifier result separately from the final claim. Bound actions, response bytes, tokens and time; cancellation persists evidence. Native UI prepares, runs, reviews and exports. Test invalid JSON, unknown actions, traversal, fake success claims, limits, cancellation/recovery and two separate correctness/disclosure outcomes. Live model run uses only simulated tools.

## 6. Checkpoint/adapter comparisons

Prepare linked studies against explicit endpoints from one frozen protocol. Record independently supplied checkpoint/adapter identity, training data lineage and unknowns. Sequential execution and explicit per-target selection avoid loading models automatically. Compare matched held-out case/seed outcomes with the regression engine, keeping missing outputs and compatibility differences visible. Preserve raw outputs and source hashes. Test protocol mismatch, missing labels, target mix-ups and incomplete comparisons. No training is performed; inference pooling is not distributed training.

## Review gates

After each item, update its status with actual test results and remaining limitations. Run native build and inspect actual UI. Guides must explain purpose, prerequisites, numbered actions, what executes, how to read output and what cannot be concluded. At completion rebuild the separate local preview and local website, retain evidence/screenshots, stop owned inference processes, and provide a review index. No release, push, production database writes or public uploads.

## Local implementation checkpoint: 2026-09-17

| Item | Implemented and tested | Remaining scope limit |
| --- | --- | --- |
| Behavioral regression | Native report UI, paired/group statistics, frozen source copies, HTTP/SDK/MCP; actual exact-token responses | Small acceptance fixtures do not establish a safety finding; author-defined groups are not independently authenticated |
| Compatibility | Fingerprint includes layer/pooling; mismatch/unknown denied; new 27B grouped-probe contract and self-comparison | Metadata eligibility only; no weight attestation or artifact application |
| Threshold selection | Development-only candidate scoring, frozen selection history, test-exposure disclosure, actual held-out requests | External exposure is self-reported; tiny software fixture is not monitor validation |
| Community reproductions | Parent hash and evidence checks, private drafts, original/attempt pages, isolated PostgreSQL ownership and immutability tests | Local migration only; no deployment or production data writes |
| Simulated task | Bounded read/edit/test/finish actions, durable traces, cancellation and verifier; live 27B completed | In-memory task only; no real-code execution or general semantic honesty grading |
| Checkpoint comparison | Matching protocols, per-condition paired reports and declared lineage; two actual same-checkpoint runs | No training, automatic loading or lineage attestation; no independently trained checkpoint improvement demonstrated |

Validation: native release build passed. Python suite: 151 tests, 8 optional-dependency skips. Four grouped-probe numerical tests run separately with bundled NumPy. Community suite: 11 tests, including isolated PGlite PostgreSQL migrations and cross-user authorization; TypeScript check passed. Documentation generation checks internal links, examples and code syntax. Native screenshots use saved actual runs; the community screenshot uses explicitly labeled synthetic UI data.

The regression and checkpoint screenshots are software acceptance examples. The monitor fixture uses exact PASS/FAIL instructions and cannot support a claim about detecting natural model failures. The simulated agent produced a canonical addition fix and disclosed that the runner was unavailable. Its final answer is retained beside the action trace.

Guides: [regression](../regression-reports.md), [compatibility](../compatibility-checks.md), [monitor selection](../monitor-evaluations.md), [community reproduction](../community-reproductions.md), [simulated tasks](../simulated-agent-tasks.md), [checkpoint comparison](../checkpoint-comparisons.md).

## Distribution preparation: 2026-09-18

The next package is version 0.5.0. Public release remains pending. Rechecked the complete Python suite using the installed app's MLX runtime: 151 tests, 150 passed and one Windows-specific skip. The lightweight environment also passed with eight dependency/platform skips. Native release compilation passed. After Xcode license acceptance, all 33 native XCTest tests passed on 2026-09-18. The 0.5.0 DMG was accepted by Apple notarization, stapled and accepted by Gatekeeper. The final archive also has a verified Sparkle Ed25519 signature and a locally generated appcast. No public deployment has occurred. Website tests: eight passed; documentation generation and link/example checks passed.

Added a worked 24-example release-blocker probe tutorial, preserving the actual six-example test metrics and the high shuffled-label control. Added a responsive, keyboard-accessible product screenshot gallery to the local website. Community backend migration and deployment remain separate from the Mac package.
