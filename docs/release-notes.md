Dyno Lab 0.4.3 adds signed in-app updates and reviewed study sharing.

## In-app updates

- Use Updates in the toolbar or Dyno Lab → Check for Updates to find new stable releases.
- Optionally enable automatic background checks. Installation always asks before restarting.
- Update downloads are verified with a dedicated Ed25519 signature, in addition to Apple Developer ID signing and notarization.
- The installed version appears in the window, app header and About panel.

## Share and continue studies

- Review selected notebook entries and export a community study package, then open research.dynolab.dev to publish it under your account.
- Import shared studies into separate local notebooks with source information. Importing never runs a model or overwrites existing research.
- Open study links from the research website in Dyno. Active notebook work is preserved before importing.

## Install this upgrade once

Version 0.4.2 and older do not have an updater. Download this release's signed and notarized Apple Silicon DMG, stop active runs, and replace Dyno in Applications once. Subsequent releases can be installed from inside the app. Studies, settings and downloaded models remain in their local data directories.

Requires Apple Silicon and macOS 14 or later. The updater does not update Windows workers. GPU pools remain experimental. Published research and model-emitted thinking are evidence to inspect, not verified explanations of model computation.
