# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Models and Discover

- **Find the draft model by name.** Searching Discover for `z-lab/Qwen3.8-27B-DFlash2`, "dflash", "draft" or "speculative" now shows it, with what it does and its download state. Hugging Face tags it as a Transformers model, so the hub search never returned it. Downloaded has a **Draft models** section, where you can delete it.
- **Plain words.** The button is now **Speculative decoding** (then **Speculative decoding ready**) instead of "Get drafter", and the app, `dyno launch` and `dyno serve` say "draft model". "Good with Dyno" names the draft model under Qwen3.8-27B.
- **Full models with "DFlash2" in their name stay listed.** Dyno now tells a draft model from its `config.json`, as `dyno launch` does, so a download such as `GLM-5.3-Flash-…-DFlash2` no longer disappears from Downloaded.

## Performance

- **Logs.** Performance has a new **Logs** source: what a model server is doing right now (waiting, reading the prompt with tokens read, speed and time left, or generating) and its full log, live. Servers started in Models now keep their log in `~/.mlx-dyno/logs/serve-<port>.log`; `dyno launch` servers are listed too.
- **The server says what it's doing.** `dyno serve` writes a line when a request arrives, starts reading its prompt (and how much came from the prompt cache), gets its first token and finishes, plus a progress line every 10 s while reading a long prompt and a warning when no token has come for 30 s. With a draft model or MTP head this progress was invisible before. `/stats` reports the same under `live.requests`.
