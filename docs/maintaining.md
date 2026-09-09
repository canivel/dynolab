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

Published ad-hoc releases remain unchanged. Local builds default to ad-hoc signing;
set `DYNO_SIGN_IDENTITY` to select an installed **Developer ID Application**
certificate with its private key. The build signs every nested Mach-O executable
and library with hardened runtime and a secure timestamp, then seals and verifies
the app. No runtime entitlements are relaxed by default.

```bash
export DYNO_SIGN_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM_ID)'
./app/package-dmg.sh
```

Signing alone is not notarization. Create an app-specific password in your Apple
Account, then run this interactively in your own terminal. Enter your Apple ID,
team ID and app-specific password when prompted; do not put them in source or chat.

```bash
xcrun notarytool store-credentials dynolab-notary
export DYNO_NOTARY_PROFILE=dynolab-notary
./app/package-dmg.sh
```

The CLI disables Python bytecode writes so running it cannot modify the sealed
bundle. Packaging tests MLX and the CLI and rechecks the app signature afterward.

The packaging script submits the signed DMG, waits for explicit acceptance, staples and validates
the ticket, and only then writes the final checksum. A failed submission or staple
stops packaging. Test the downloaded/stapled DMG on a clean Mac before publishing.
For rejected submissions, retrieve the submission log with `xcrun notarytool log`
using the same Keychain profile and investigate rather than bypassing the check.

The GitHub release workflow requires signing and notarization; missing credentials
fail the build instead of silently producing an ad-hoc release. Configure the
`release-signing` GitHub environment with version-tag-only deployment access
(`v*`) and the following environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded password-protected Developer ID Application certificate **and private key**, exported as `.p12` from Keychain Access |
| `APPLE_CERTIFICATE_PASSWORD` | The password chosen when exporting that `.p12` |
| `APPLE_ID` | Apple Account email used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

Set environment variables `APPLE_TEAM_ID` and `APPLE_SIGN_IDENTITY` to your team ID
and the complete Developer ID Application certificate name. A `.cer` file alone
does not contain the private key and cannot sign a release.

The release job imports the certificate into a temporary keychain on the hosted
Mac, stores notarization credentials there, and removes the keychain in an
`always()` cleanup step. PR jobs never reference this environment or these secrets.
Inspect changes to the release workflow before merging. Add an independent
required environment reviewer when another trusted maintainer is available.

Local Keychain credentials are not automatically copied to GitHub. Upload secrets
through GitHub's environment settings or `gh secret set`, never through source,
chat, logs, issue comments or PR descriptions. Keep CI signing marked unverified
until a complete hosted release run succeeds.

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
