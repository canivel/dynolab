# Dyno Lab 0.5.0 release candidate

Prepared locally. The public download remains 0.4.3 until signing, notarization and release validation are complete.

## Research workflows

- Create controlled comparisons with a guided question, prompt and run-settings form. Your draft is retained when you leave to start a model or pool.
- Review responses with visible labels or use the separate review queue with condition and model labels hidden. Pass, fail and uncertain selections remain visible.
- Inspect result counts, ungraded attempts and condition summaries without treating unfinished review as a pass.
- Start an activation, probe, intervention or SAE investigation from a saved study. Review copied data, labels and scenario splits before running.
- Select probe layers and regularization on validation data, then inspect test metrics and majority, shuffled-label and text-length controls.
- Evaluate response monitors, compare paired study results, inspect artifact compatibility and run bounded simulated tasks through the Lab, SDK, API and MCP.

## App usability

- Consistent labeled forms for studies, journal entries and research settings.
- Model readiness checks before execution, with saved work retained when an endpoint is unavailable.
- Compact completed-download notices with actions to open the downloaded library or dismiss the notice.
- An update indicator appears only when a newer version has been found. Manual checking remains in the application menu and settings.

## Guides and product examples

The documentation includes a [complete probe tutorial](probe-tutorial.md), screenshots and guides for the new research workflows. The website preview adds a product gallery with full-size screenshots.

These tools record experiments and support review. Probe accuracy is not evidence of causal use or model safety. The tutorial's shuffled-label control scored 5/6, so its 6/6 probe result must not be presented as a robust research finding. Community reproduction features require a compatible community deployment.

## Upgrade

Install the signed release through the existing updater once 0.5.0 is published, or download its DMG. Finish active work before restarting. Saved studies and downloaded model files live outside the app bundle. The Mac updater does not update Windows workers.

---

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
