# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Models and Discover

- **Good with Dyno.** Discover opens with a short list of models that run well with Dyno, what each is good for, and only the ones that fit this Mac.
- **Get the drafter in the app.** Qwen3.8-27B rows in Discover and Models have a **Get drafter** button that downloads the DFlash2 drafter (it never showed up in the search). Drafters no longer appear as models to start, and `dyno launch` and `dyno models` skip them: `dyno launch claude --model qwen3.8-27b` no longer picks the drafter and fails with "missing rope_theta". `dyno serve` on a drafter now says which model to serve instead.
- **Which build is which.** Downloaded models show their full lab/model name (`lmstudio-community/Qwen3.8-27B-MLX-4bit`) under the short name, so builds of the same model from different labs no longer look identical.
