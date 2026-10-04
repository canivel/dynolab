# Human review and monitor evaluation

Local development only. This is work package 2 of [research workflows](research-workflows.md). No release or publication in this work package without review.

## Stage A: preserve reference judgments (implemented locally)

The native review sheet uses a dedicated allowlisted API projection rather than passing the complete study into its response cards. Save one shuffled queue per reviewer. Freeze queue membership to the latest completed attempts at preparation. Reveal is permanent for a session and records a timestamp. Every judgment retains the frozen protocol hash, reviewer, note, prior-exposure declaration and whether context was hidden when saved. Revisions append; existing disagreement summaries use the latest judgment per reviewer.

Shared prompts, rubrics and answer text remain visible and can disclose condition information. Normal study routes/files retain full context. This is not an access-control boundary or a claim of independent blind review. Review names are local and self-reported. Imported evidence stays read-only. Review requires no running endpoint.

Validation: unit tests for allowlisted fields, permanent reveal, stable restart/resume, peer-label exclusion, cross-session item rejection, incomplete runs, queue membership, read-only imports and disagreement preservation. HTTP SDK and real stdio MCP tests cover preparation, read, labels and reveal. Native acceptance uses the saved four-response Qwen3.8-27B study, under the explicitly named “UI acceptance (automated)” reviewer, with prior exposure declared. This is software acceptance, not an independent human evaluation.

## Stage B: frozen monitor protocol (next)

- Create a separate monitor-evaluation record referencing the target study content hash and a frozen human-label snapshot. Never write monitor judgments into human-label records.
- Define the positive class explicitly (for example, rubric failure), rubric revision, monitor endpoint/model, generation settings, and evidence view: answer-only, thinking-only, or combined. Action-only stays unavailable until recorded action traces exist.
- Missing thinking becomes an excluded item, never an answer fallback. Metadata and condition labels are absent from monitor inputs unless the protocol explicitly includes them.
- Freeze development/test group membership from the source protocol. Reject group leakage and absent held-out groups when claiming held-out evaluation. Exploratory development-only mode remains clearly named.
- Capture threshold and its development-only selection history before test labels/results are evaluated. Retuning creates a new revision and discloses reuse of held-out data.
- Preflight shows eligible/excluded counts and maximum request/token cost. Preparation has no inference side effects.

Acceptance: mutation and leakage tests, source hash mismatch, missing-reference exclusions, explicit class semantics, forbidden view fields, and no implicit execution.

## Stage C: bounded monitor runner

- Reuse the explicit loopback endpoint client with redirects disabled. Serial requests, persisted attempts, cancellation, recovery and timeout behavior follow controlled studies.
- Put output evidence inside a structured data envelope. No tools or code execution. Malicious instructions in the target answer cannot modify frozen protocol fields; monitor semantic susceptibility is still possible and must be tested.
- Require a strict score schema with finite score in [0,1] and optional rationale. Malformed/truncated answers are invalid attempts, not negative predictions. Store raw output separately.
- Record target and monitor model identities independently; unavailable revisions remain unknown. Do not label a second pass by the same model “independent verification.”

Acceptance: prompt-injection fixtures, malformed JSON, NaN, missing thinking, token exhaustion, cancellation/restart and endpoint loss. No network beyond the selected local endpoint and no monitor tools.

## Stage D: evaluation and native report

- Join predictions to frozen reference IDs, with one latest valid prediction per item. Count ungraded, uncertain, disputed, missing-view and invalid predictions separately.
- Show confusion matrix, class denominators, precision, recall, false-positive rate and Brier score where applicable. Empty-class rates are unavailable, not zero.
- Filter disagreements and missed positives; show source evidence and both judgment histories. Keep development/test reports separate. Do not infer task-level significance from repeated samples.
- Native UI: select source → configure view and monitor → review budget → run → inspect metrics and disagreements. Saved reports remain readable offline.

Acceptance: hand-calculated metrics including all-negative and empty classes; a live small-model demonstration compares two evidence views on the same frozen source. Preserve negative results. At least one independent case group is needed for held-out mode. Screenshots must identify sample size and exploratory status.

## Stage E: interfaces and local review package

Add versioned HTTP schema, SDK and MCP wrappers alongside each new endpoint. MCP preparation/read cannot execute; run is separate and explicit. Test transport parity and malformed inputs. Update native handbook, local website and compatibility table only when the corresponding behavior is tested. Deliver evidence bundle, test log, real UI screenshots and a local preview. Do not upload study evidence or release binaries during these stages.
