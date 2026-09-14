# Thinking on/off feasibility comparison

Freeze before running: the first two published extraction questions under their positive and negative instructions, plus the first two neutral evaluation questions used in the preceding pilot. Every case runs with thinking disabled and enabled. Twelve responses, six matched pairs. These previously observed questions are pilot data, not a new blind test set. Prior studies remain intact.

Same Qwen3.8 revision, layer 32, greedy decoding, 768 output tokens in both modes. Report complete, incomplete, missing-marker and ambiguous-marker outputs separately. If the token budget ends before a final answer, record that; never call generated thinking a final answer. No retries with larger budgets to hide incomplete outputs. Keep all raw text, finish reasons, timings and package versions.

The comparison changes the tokenizer's thinking template flag. It does not guarantee that all computation is identical apart from a text field. Explicitly emitted thinking is model-generated content, not privileged evidence of intent or a guaranteed causal account.

After generation, replay the exact serialized prompt plus response through a fresh forward pass. Capture raw block-32 norms with prompt, thinking, delimiter, and final-answer token phases. Check tokenization boundaries; reject ambiguous spans and report failures. Do not silently truncate replay inputs. The combined replay limit is 1024 tokens. Do not infer trait strength from vector magnitude.

Primary feasibility outcomes: final-answer availability, token usage, observed answer differences, and whether phase-linked measured artifacts are valid. This small exploratory comparison cannot establish a general safety benefit of enabling thinking. All qualitative assessments are explicitly model-assisted unless independently reviewed.
