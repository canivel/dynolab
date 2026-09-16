# Updating Dyno Lab

Updater-enabled builds have an **Updates** button in the main toolbar and
**Dyno Lab → Check for Updates…** in the application menu. The panel shows the
installed version and links to release notes. Enable **Automatically check for
updates** to check periodically. Checks are off until you enable them.

When an update is available, review its notes and choose whether to download
and install it. Installation requires a restart confirmation. Finish requests
and experiments first: restarting stops the coordinator, model server and
router. Studies and model downloads stored outside the app bundle are retained.
This does not update the Windows worker or stop unrelated processes on a worker.

**Migration:** versions released before this updater was added, including
0.4.2, need one manual installation of an updater-enabled release. They cannot
gain an updater remotely. Replace the app in Applications using the new DMG.
The first updater-enabled release is 0.4.3. Its published `appcast.xml` starts
the stable update channel.

## Release maintenance

We use [Sparkle 2](https://sparkle-project.org/documentation/) pinned to 2.10.0.
The app verifies the download with the public Ed25519 key in
`app/sparkle-public-key.txt`. Apple Developer ID signing and notarization remain
required by the release workflow. The private Sparkle key is separate from the
Apple signing certificate and must never be committed.

The development machine stores the key in macOS Keychain under the Sparkle
account `dynolab`. Back it up securely. Add its exported value as the
`SPARKLE_PRIVATE_KEY` secret in GitHub's protected **release-signing** environment.
Use Sparkle's official `generate_keys --account dynolab -x <private-file>` tool
to export it. Transfer it through a secure secret input, delete the temporary
file afterward, and never paste it into an issue, log, or commit.

The existing reviewed-tag workflow:

1. Tests and builds the app with the embedded Sparkle framework and helpers.
2. Signs nested code, signs the app, and notarizes/staples the DMG.
3. Signs that final DMG using the protected Sparkle secret.
4. Verifies the signature against the public key shipped in the app, then
   generates `appcast.xml` and includes it in release checksums.
5. Creates a **draft** GitHub release for review, as before.

Publish a tested stable release with its DMG and appcast, and mark it as the
latest release. Installed apps read
`https://github.com/canivel/dynolab/releases/latest/download/appcast.xml`.
The archive URL inside that feed points to the exact versioned release.
Do not replace a signed DMG in place. Release a higher version instead.
Prereleases do not receive a stable appcast and must not be marked latest.
Never mark a legacy release without an appcast as latest after rollout.

## Required release smoke test

Use a disposable copy of an updater-enabled, signed app with a lower bundle
version. Publish a test feed to a separate HTTPS location and point only that
test bundle at it. Keep the production feed unchanged until the test passes.

- Check that Sparkle finds the newer version and displays its release notes.
- Install into Applications, relaunch, and verify the version changed.
- Confirm studies, settings and downloaded models are preserved.
- Verify **Not now** cancels the restart without stopping the pool or server.
- Verify **Restart and update** stops app-owned services before relaunching.
- Verify a modified archive or an archive signed by a different key is rejected.
- Verify offline checks show an error and a current version shows no update.

Local tests cover appcast signature, archive tampering, wrong keys, filename
and version validation. A compile or signature test alone is not evidence of
a successful end-to-end installed-app update.
