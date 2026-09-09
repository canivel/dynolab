# Maintaining Dyno Lab

A native open-source app has two trust boundaries: deciding which source changes land, and deciding which compiled binaries reach users. Anyone can propose a PR; only authorized maintainers can merge or release. Tests, review, branch rules and release provenance complement one another. They cannot guarantee that a change has no bugs.

## Main branch and reviews

Use protected `main` with PRs, code-owner review, stale-review dismissal, resolved conversations, current passing checks, blocked force pushes and blocked deletion. The required checks are **Python API and SDK** and **Native macOS build**. Keep job names stable. Do not use path filters that leave a required check permanently pending.

`.github/CODEOWNERS` assigns @canivel as owner. GitHub settings must enforce it; the file alone is not a merge gate. For a solo maintainer, a narrowly scoped administrator bypass **through pull requests only** avoids asking the author to approve their own PR. Use it only after checks pass and self-review is recorded. Community PRs still require approval. Adding maintainers should be deliberate; remove the solo exception when independent review is practical.

The workflow runs portable Python/API/SDK/MCP tests and documentation checks, plus Swift tests and a native app-bundle build on a disposable GitHub-hosted Mac. Neither job receives release credentials. Fork runs require maintainer approval according to repository settings. Do not approve an unfamiliar contributor's workflow without inspecting changes to workflows, build scripts, dependencies and executable hooks.

## Dependencies and workflow security

Actions are pinned to verified full commit SHAs; Dependabot proposes weekly action and uv dependency updates. Review updates through the same PR process rather than merging them automatically. `uv.lock` records Python versions and hashes; packaging exports that lock and verifies runtime dependency hashes. Build-backend tooling, the downloaded standalone Python runtime and the macOS SDK remain part of the build environment: this is not a claim of byte-for-byte reproducibility.

Keep repository workflow permissions read-only and disable Actions creating/approving PRs. Build jobs have `contents: read`, and checkout does not retain credentials. Only the separate release publication job can write release assets or request provenance attestations. It downloads the current run's artifact and never executes the app or checks out source. Avoid `pull_request_target` for executing contributor code; never put an untrusted fork on a self-hosted runner connected to private data.

## Release checklist

1. Merge reviewed changes after required CI passes. Update the package version, release notes, compatibility notes and public documentation. Do not silently replace an existing version's assets.
2. On an idle Apple Silicon development Mac, run the full MLX regression suite and `tests/lab_acceptance.py` with a temporary service/data directory. Verify neutral intervention controls, resident capture followed by normal inference, history reload, SDK and MCP, and cancellation cleanup. Hosted native compilation is not a real-model GPU acceptance test.
3. Create a version tag (`vX.Y.Z`) at a reviewed commit on `main`. Restrict version-tag creation, updates and deletion to release maintainers. The workflow verifies tag existence, ancestry, version and architecture before building.
4. The release workflow builds the full DMG, Python wheel/source archive, runtime CycloneDX SBOM, lockfile and SHA-256 manifest. It verifies the DMG and code-signing structure, then attests the binary artifacts and creates a **draft release**. Existing releases are not overwritten.
5. Download the draft DMG. Verify checksum and provenance, mount/install it, launch from Applications, test the bundled CLI/MCP after relocation, then run a small model and a saved-study round trip. Inspect third-party notices and confirm no local paths, prompts or credentials were bundled. Test on the minimum supported macOS before claiming compatibility.
6. Publish the draft only after reviewing this evidence. Keep the tag and published artifacts immutable. If a bad version ships, mark it clearly, publish a fixed version and document rollback; do not move its tag or secretly swap the DMG.

A future DMG can be checked with:

```bash
shasum -a 256 -c Dyno-X.Y.Z-arm64.dmg.sha256
gh attestation verify Dyno-X.Y.Z-arm64.dmg --repo canivel/dynolab
```

Use the actual downloaded filename. These checks are complementary: provenance connects a file to the workflow/repository; it does not certify the source code's safety.

## Developer ID signing and notarization

The current app is **ad-hoc signed, not Developer ID signed or notarized**. The repository safeguards do not change that. Production macOS distribution should use a Developer ID Application certificate, hardened runtime, secure timestamp, notarization with `notarytool`, and a stapled ticket. Validate the nested Python executables and MLX libraries with appropriate entitlements before shipping.

Provision Apple credentials through a protected release environment, never in source, PR workflows or the browser conversation. Use a temporary keychain on an ephemeral release runner and remove it after signing. Independent review/approval of that environment is preferable once another trusted maintainer exists. Certificate/account setup and a tested signing workflow are still required before claiming this protection.

## Repository settings audit

GitHub settings live outside Git. After creating or transferring the repository, verify:

- Main ruleset is active, targets the default branch and requires the two named checks plus PR review/conversation resolution.
- Version-tag rules restrict creation and block updates/deletion except deliberate release-maintainer operations.
- Default Actions token is read-only; Actions cannot approve PRs; outside-collaborator runs require approval.
- Private vulnerability reporting, dependency graph/alerts, secret scanning and push protection are enabled where available.
- No unexpected collaborators, deploy keys, self-hosted runners or privileged app permissions have been added.

Do not assume a checked-in workflow or CODEOWNERS file applies these settings automatically. Record what was actually enabled and any plan/account limitations.

## References

- [GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
