# Contributing to Dyno Lab

Thanks for helping make local model research easier to inspect and reproduce. The project is maintained by @canivel. Opening a public pull request does not grant permission to merge it or publish a release.

## Propose focused changes

Open an issue before large features, architecture changes, new dependencies, altered network exposure or incompatible SDK/API changes. Explain the user/research problem and how you will validate the behavior. Small bug fixes can go straight to a PR. Keep unrelated refactors separate.

Fork the repository, create a branch, and target `main`. Use the PR template. Include a concrete before/after example, validation results and relevant compatibility risks. Native UI changes need screenshots from the app. Generated visuals must not masquerade as measured research results. Never include private prompts, model weights, credentials, personal IPs or local history.

## Development and checks

The native app requires an Apple Silicon Mac, macOS 14+, Xcode command-line tools and Swift 6. The portable Python client/tests can run on Linux with Python 3.12. Use uv 0.12.9 to match CI:

```bash
uv sync --locked --extra mcp --extra docs --python 3.12
PYTHONPATH=src uv run --frozen python -m unittest discover -s tests -v
uv run --frozen python scripts/check-docs.py
uv build
# On macOS:
swift test --package-path app
./app/build.sh --slim
```

The slim app verifies native compilation and packaging; it does not include the Python runtime and is not a distributable release. Use `./app/package-dmg.sh` for a complete local package. Bundled runtime dependencies come from `uv.lock` and are verified against hashes. When changing dependencies, run `uv lock`, review the lockfile diff and explain the change.

CI deliberately does not download large models or run community PRs on a maintainer's Mac. Tests requiring MLX/Metal are skipped in portable CI. On a quiet development Mac, install serving dependencies with `uv sync --locked --extra serve --extra mcp --extra docs`, then run the full Python suite and the opt-in `tests/lab_acceptance.py` against a temporary Lab service. Use a separate port and data directory; never stop another person's serving process to make a test fit.

## Research and compatibility requirements

For serving/capture changes, verify unchanged baseline logits, cleanup after errors/cancellation, model identity checks, memory behavior and continued serving. Include the small Qwen acceptance suite for research changes. Record exact model revision, quantization, seed, layers and input mode.

For probes/SAEs, use explicit train/test splits and report controls. Do not turn activation norms, token likelihood or probe scores into claims of safety or human-readable internal reasoning. Document unsupported architectures.

Preserve saved-history readability and `/lab/v1` contracts where possible. Add migration/rollback notes when a change breaks saved data, client code or launch behavior. Update the app handbook, SDK guide, API reference and OpenAPI together when relevant; the website docs are generated from those Markdown files.

## Review and merge

Automated checks are necessary but do not establish correctness. The maintainer reviews scope, code, regression evidence, dependencies and security-sensitive changes. A PR may be returned for smaller scope or declined. Passing CI does not imply acceptance. Review changes after the last approval; do not append unrelated edits after review.

Community PR workflows use read-only tokens and no publishing/signing secrets. Workflow changes are code-owned. Never introduce `pull_request_target` code execution or run fork code on a self-hosted machine. See [maintenance and releases](docs/maintaining.md) for the release process and repository settings.
