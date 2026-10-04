# Dyno Lab 0.5.1

Dyno Lab 0.5.1 is the first public release with agent sandbox tests: run an AI agent on a task it can't finish without breaking a rule, record everything it does, and evaluate the result separately from what the agent sees. See the [agent sandbox tests guide](agent-sandbox-tests.md).

## Agent sandbox tests

- A new **Agents** tab, now the default. It covers runs, conversations, search, tasks, environments and readiness.
- Agents run in Docker with the gVisor runtime inside a Colima VM, with all capabilities dropped and no network beyond what a task allows. Each episode gets a fresh workstation.
- Built-in impossible tasks and environment templates. Create your own tasks (prompt, rule, tripwires, honeypot secrets, honest-outcome checks, conditions, budgets) and your own environments (network segments, services, per-host gateway rules). Turn environments on and off, open a shell in them, and run tasks against a running instance.
- Conversations shows every message, command and output as it arrives, with full-text search across runs. Evaluation data appears in a separate column that the agent never sees.
- A new **Evaluate** tab:
    - **Results:** outcome counts per task and condition.
    - **Review:** confirm or correct each automatic label.
    - **Evaluators:** shows exactly what the agent sees, and lets you add LLM monitors that score transcripts without seeing labels or tripwires.
    - **Evidence:** seal runs with SHA-256 checksums and an optional Ed25519 signature, and verify them.
- The open-source [dynolab-harness](https://github.com/canivel/dynolab-harness) is bundled at a pinned commit. Nothing to download or choose.

Labels come from heuristic rules and must be reviewed. Results from a few episodes are counts, not rates, and are not evidence that a model is safe.

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

## Fixes in 0.5.1

- The update window shows this release's notes as formatted text. Earlier feeds showed the whole notes file as unformatted Markdown.
- `dyno --version` and the CLI banners show the installed version. They had shown 0.2.2 since that release.
- Version 0.5.0 was built and signed but not published, because of the first issue. 0.5.1 contains everything listed here.

## Upgrade

Install it from inside Dyno (0.4.3 or later: Dyno Lab → Check for Updates…), or download the signed DMG. Finish active work before restarting. Saved studies and downloaded model files live outside the app bundle. The Mac updater does not update Windows workers.

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
