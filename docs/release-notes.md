Dyno Lab 0.4.0 adds research notebooks and visible, recoverable model runs.

## Studies and live responses

- Organize a research question, hypotheses, prompt revisions, notes and saved results in Studies. Review history without a running model; connect a healthy endpoint before executing.
- Stream model-emitted thinking and answers in a dedicated window. Follow incoming text, inspect earlier output, or cancel. Partial output is retained on failure.
- Set thinking mode and the output budget in visible controls with a slider and presets. Token-limit warnings distinguish incomplete responses from completed answers.
- Archive a query and its result together; restore them without changing the original evidence. Later branches and notes remain intact.
- Save working drafts, attach evidence, export notebooks and record local voice notes. On-device transcription depends on macOS language support and permissions; no cloud fallback is used.
- Replay an explicit local protocol through the native notebook runner. Empty system instructions omit the system message for controlled tests.

## Research and integration

Generation artifacts can display model-emitted thinking separately from final answers. The Lab SDK/API can request bounded response-token replay measurements; these are fresh forward passes, not traces of the original generation. Existing model serving and experimental GPU pool features remain available.

The Typebulb reproduction is an exploratory transcript audit with explicit local settings. It is not a hosted leaderboard reproduction, general safety score, or causal explanation of the model.

## Packaging

Bundled pool libraries resolve relative to their executable rather than a temporary build directory. Release validation checks the relocated runtime before publication.

## Upgrade

Stop active runs before replacing the app. Download the signed and notarized Apple Silicon DMG from this release. Existing models and notebook evidence remain in their local data directories. Requires macOS 14 or later.
