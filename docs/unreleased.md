# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Models and Discover

- **Find the draft model by name.** Searching Discover for `z-lab/Qwen3.8-27B-DFlash2`, "dflash", "draft" or "speculative" now shows it, with what it does and its download state. Hugging Face tags it as a Transformers model, so the hub search never returned it. Downloaded has a **Draft models** section, where you can delete it.
- **Plain words.** The button is now **Speculative decoding** (then **Speculative decoding ready**) instead of "Get drafter", and the app, `dyno launch` and `dyno serve` say "draft model". "Good with Dyno" names the draft model under Qwen3.8-27B.
- **Full models with "DFlash2" in their name stay listed.** Dyno now tells a draft model from its `config.json`, as `dyno launch` does, so a download such as `GLM-5.3-Flash-…-DFlash2` no longer disappears from Downloaded.
