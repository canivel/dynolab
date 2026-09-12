# Inside AI Models: Learning by Experimenting

Author: Danilo Canivel. Drafts for Medium and Substack, not automatically sent to subscribers.

Audience: curious newcomers, ML practitioners and researchers interested in AI behavior. Each title names a concrete question; the shared series name and part number connect the posts. Define technical terms in the subtitle or opening. Dyno is the experimental workbench, not the subject or a product pitch.

Editorial promise: one question per post, real data, reproducible settings, clear controls, the negative results, and a specific next question. Personal voice, thoughtful confidence and light observational humor. Humility comes from precise claims, curiosity, credit and openness to correction, not apologizing for the work or making the author’s competence a punchline. No defensive disclaimers, inflated safety claims, invented personal history or em dashes. Credit Fable and Astra as build collaborators without attributing unverified scientific conclusions to them.

1. **Inside AI Models, Part 1: How Can We Understand Their Behavior?** Origin, honest scope, one positive and one negative example, open-source links. Full draft in this directory.
2. **Inside AI Models, Part 2: What Happens Between a Prompt and an Answer?** Activations on a small model, token and layer comparisons, normalization traps, why activation magnitude is not an explanation. Record a fresh run before writing results.
3. **Inside AI Models, Part 3: Can We Catch a Model’s Mistakes Before It Answers?** The Qwen3.8 identifier-fidelity probe: 48/24 split held out by identifier, layer 32, actual wrong outputs, ordinary controls and token-count baseline. Use the saved run and captioned video. Follow-up validation must be new and predeclared, not retuning this test set.
4. **Inside AI Models, Part 4: How Can We Test What Causes a Model’s Answer?** Intervention and causal patching with clean/corrupted prompts, neutral/restored controls, tokenizer alignment. No “found the circuit” claim from a single intervention.
5. **Inside AI Models, Part 5: Can We Find Meaningful Patterns Inside a Neural Network?** Small SAE experiment, reconstruction versus sparsity, counterexamples, limits of labels and imported artifacts.
6. **Inside AI Models, Part 6: Can Home Computers Work Together to Run Larger AI Models?** Real 235B pool evidence, 128 GiB Mac plus RTX 5090, model allocation, CPU participation, network cost and loading time. Distinguish endpoint sharing from model sharding. Record normal chat as well as the dashboard.
7. **Inside AI Models, Part 7: How Do We Know an AI Experiment Is Trustworthy?** SDK/API, saved settings, model revisions, seeds, held-out data, exporting artifacts, reproducibility limits.

Medium packaging: title, subtitle, short opening paragraphs, two actual screenshots with captions, headings, link to hosted video, and a question for readers. Suggested topics: Artificial Intelligence, Open Source, Machine Learning, AI Safety, Programming. No paywall requested.

Substack packaging: same core article with subtitle and images, free draft. End with the specific reader question and subscribe invitation; do not auto-email. Use a hosted video link if direct upload is unavailable. Do not send Notes or promotional messages automatically.

Series titles are working titles. Future articles require actual experiments before their results are written. There is no recurring publication schedule yet.
