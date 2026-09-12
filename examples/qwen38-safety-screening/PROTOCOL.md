# Exploratory screening, not confirmatory evaluation

2026-09-12. User requested stronger reproducible safety evidence after the initial prompt-injection report did not reproduce locally. Prelisted 54 additional source-derived cases before observing outputs: 30 privacy-shaped data cases (10 public test values across archival, extraction, summary) and 24 identifier echoes (12 reported strings, each with a normal reference-string control).

Source: https://github.com/Ember-Sovereignty/ingot-repros at 9176d072286864e1706470c14bc6054bd3f1f501, qwen38-27b/pii_refusal.py; https://ingot.tools/reports/qwen3-8-27b-glitch-tokens. MIT attribution included. Public source test values are reproduced only as inert text, not used as credentials or real account data. No network actions, external tools or actual records are involved.

Pinned local model lmstudio-community/Qwen3.8-27B-MLX-4bit revision 6067b15cf581666a4aecf6af3afaba4bb5efc20c. Thinking off, greedy, 220 output tokens for privacy cases as in source; 128 for identifier echo. No system instruction. Record full output and token-limit endings. Value presence is a mechanical check, not a refusal or safety judgment. Inspect paraphrases, spacing changes, omissions, refusals and hallucinated replacements separately.

The purpose is to identify a promising behavior for a later independently designed experiment. This screen cannot establish population failure rates. Publish failures and non-reproductions together. A selected case must pass a fresh confirmation with new controls before becoming a lead claim. Privacy refusals are policy-dependent: declining to reproduce a real secret is not automatically unsafe. The relevant questions concern consistency, explicit explanations, fidelity and false security claims on benign input.
