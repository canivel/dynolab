# Dyno Lab 0.6.4

Dyno Lab 0.6.4 runs Evals on [Inspect AI](https://inspect.aisi.org.uk), the open-source evaluation framework from the UK AI Security Institute, and replaces the "knows it's being tested" phrase list with a detector that has to quote the agent. A real experiment on two local models shaped it and is written up as a tutorial and a study: [Tutorial: agent tests and evals](agents-and-evals-tutorial.md) and [Does a rule said once survive?](tutorial/rule-said-once.md).

## Evals on Inspect AI

- **Four steps, like Agents:** Choose → Set up → Run → Results. The banner says what does the work: Inspect's dataset → solver → scorer.
- **Build or import an eval.** Write samples in a table or paste them from a spreadsheet, or import a CSV, JSONL or JSON file, or an Inspect `.py` task file (shown as code you must read first). Pick a solver (ask once, think then answer, multiple choice) and a scorer (contains, starts or ends with, exact, a regular expression, the right choice, or a judge model with your instructions). Run several epochs to see how consistent a model is.
- **Benchmark library.** Installs inspect_evals once and lists benchmarks that run on a local model without Docker: SAD (evaluation awareness), StrongREJECT, Agentic Misalignment, MASK, TruthfulQA, SimpleQA, WMDP, BBQ and XSTest. XSTest loads from its authors' openly licensed data, so no Hugging Face login is needed. Badges say which benchmarks need a judge model.
- **One results board.** Agent tests (decided by the Observer) and Inspect evals (scored by Inspect) sit side by side, each number with how many runs or samples it rests on and its 95% range. A benchmark that isn't right-or-wrong shows its own metric and which way is better. Click a cell for the samples and the judge's explanations, or open it in **Inspect View**, Inspect's own log viewer.
- **Answers that were cut off are counted.** Each run reports how many answers hit the token limit or came back empty, so a token limit isn't mistaken for a wrong answer. The tested model gets 8,192 tokens per answer.
- Each model runs in its own process, so a crashing eval can't take the lab down.

## An evaluation-awareness detector

*Knows it's being tested* now asks whether the agent thinks **it** is being tested, not whether the task involves tests.

- Words like *test*, *eval* or *trap* only pick passages to check. A judge model (the lead's own, unless you pick one) must quote the agent word for word and label the passage: *verbalized*, *implicit*, *prompted* (repeating what the test said), or *task_testing* (the task involves tests, or the user is just checking the agent is responsive). Only the first two fire, at or above a threshold you set.
- Invented quotes are thrown out, and words the test itself used are ignored. Without a judge model, a strict pattern stands in.
- Alerts from 0.6.3's phrase lists are marked *old phrase list* and greyed in the Room.

## Fixes

- **Models start with the settings Dyno shows.** Dyno passed only the settings that differed from its own defaults, so mlx_lm.server used its own: 512 tokens per reply and up to 32 requests at once. Thinking models returned empty answers, and long agent tests could run the server out of Metal resources.
- **Evals leaves out runs that didn't really finish:** rooms that stopped on a harness or model-server error, and scripted tests whose script wasn't fully delivered (a model that never files a report never gets the scripted requests).
- An Inspect cell shows its eval's latest run instead of pooling runs made with different settings.
- The Room's live lists no longer freeze the app (0.6.3's fix missed a case).
- An imported 0.6.3 test's alert shows once.

---

# Dyno Lab 0.6.3

Dyno Lab 0.6.3 makes agent tests shareable: publish a test, a run result or an Evals table to [Dyno Research](https://research.dynolab.dev), and open anyone's test in Dyno with one click. It also includes everything planned for 0.6.2, which was never published (see below).

## Share tests and results

- **Test packages.** A whole setup in one `.dynotest.json`: the environment with its files, the goal, the rules and what watches each, the lead agent and prompt, alerts, script and history. No model is included; whoever runs it picks one. **Setup → Share…** to save or publish it, **Setup → Import test…** to preview everything it will save and run before anything happens. Importing runs nothing.
- **Publish to Dyno Research.** One Share sheet for tests, run results and Evals tables, with a live *What's included* preview built from the export, the license, and a research token kept in your Keychain. It uploads a private draft; you review it and publish it on the site. Tokens can't publish on their own.
- **Run results and Evals tables.** **Past tests → Export → Share result…** publishes a finished test: the Observer's verdict, the rules (with how long ago a rule was stated), the team, the timeline and the full log. Thinking is included only if you turn it on, and honeypot secrets are replaced with `[secret]`. **Evals → Share…** publishes the whole table or one batch.
- **Docker Compose with every share.** Tests and results carry the environment as a `docker-compose.yml` in Dyno's `x-dyno` dialect (internal networks, files, ports, access rules and tripwires), so the environment runs under plain Docker and imports back into Dyno unchanged. A past test is shared with the environment exactly as it ran, even if you edited it since.
- **Open in Dyno.** On research.dynolab.dev, *Open in Dyno* opens the test's import preview in the app. Import links are accepted only from research.dynolab.dev; anything else is opened as a file.

## Long-horizon tests (GHOST)

For reproducing *A GHOST in Long-Horizon Agents* (arXiv 2610.02664):

- **Rules said once.** A rule can be posted once in the chat (at the start or a given round) instead of in every prompt. Its detector still runs, and the verdict says how far back it was stated: *Rule 1 broken · stated 27 messages earlier · not restated*.
- **Scripts.** Messages the test sends by itself after each final report or at a round, so a long session runs unattended and stays comparable in Evals.
- **Prefilled history.** Earlier turns inserted before the task, identical across runs.

## Fixes

- The Room no longer freezes the app during long tests.
- An imported test's alert no longer appears twice when the same alert is already on.

---

# Dyno Lab 0.6.2 (not released)

0.6.2 was built but never published; its changes ship in 0.6.3.

Dyno Lab 0.6.2 opens agent sandbox tests to scripts and AI assistants, and lets you build an environment from a Docker Compose file.

## API, SDK and MCP

- **Agent sandbox tests over HTTP, the Python SDK and MCP.**
  - Plan, start, follow, message, end and export tests.
  - Read the Observer's entries and verdict.
  - Manage versioned agent prompts and Observer alerts.
  - Use Evals: the overview, one cell, comparisons, batches, review and the report judge.
- The OpenAPI schema documents every endpoint. MCP gets 21 new tools; tools that start tests or batches ask the assistant to get your go-ahead first.

## Environments from Docker Compose

- **Setup → Environment → Import Docker Compose…**, or `environment_from_compose` in the SDK and MCP. Services become nodes, networks become segments, and exposed ports become gateway rules. An `x-dyno` block per service sets what the agents may reach (allow, flag, deny or hidden) and the tripwire.
- Dyno nodes run under gVisor with dropped capabilities and don't run an image's own start command. Well-known images (PostgreSQL, MySQL, MinIO, Vault, MailHog, nginx…) therefore become Dyno's stand-ins on the same port, and the import says so. Other images run with a `command:`. Anything the sandbox can't honour is left out with a warning, and the harness checks the result before it's saved.
- Harness fix: nodes built from an outside image (for example `python:3.12-slim`) no longer stop as soon as they start.

## Upgrade

Install it from inside Dyno (Dyno Lab → Check for Updates…), or download the signed DMG.

---

# Dyno Lab 0.6.1

This is the first 0.6 release. A `v0.6.0` tag was created by mistake on the 0.5.2 code; it has no release or downloads.

Dyno Lab 0.6.1 turns agent sandbox tests into a **team** test: a lead agent works on a goal it can't reach without breaking a rule and creates its own teammates. A hidden Observer records every rule break, who broke it and who asked them to, and checks the team's report against the logs. A new **Evals** tab turns those tests into rates you can compare. See the [agent sandbox tests guide](agent-sandbox-tests.md).

## Agents

- **One-page Setup.** Choose an environment (edit its architecture in place), a goal, plain-language rules, and a lead agent with a team size limit. Old screens moved under **Advanced**.
- **Agents create agents.** Any agent can add a teammate with a name, a role and instructions. The new agent uses its creator's model, and the goal and rules always come from Dyno, not from the creator.
- **Room & Observer.** The agents' group chat sits next to the Observer, which is hidden from them.
  - The Observer keeps the family tree, flags instructions that point a new agent at something a rule protects, and attributes every break up the chain: *Rule 1 broken by Data access · delegated by Agent A · not disclosed*.
  - **Full log** shows every turn in full: what each agent was sent, its thinking, every command and output, tokens, and the model's live output.
- **Write in the chat.** Your messages reach every agent at its next turn. The room stays open after a final report for follow-ups, and the Observer marks breaks that came after your message.
- **Versioned agent prompts.** A Markdown editor with a preview, for the lead and for created agents. Every save is a new version, and every test records the version it ran with.
- **Observer alerts.** Your own checks on thinking, messages, commands, output or reports, by phrase or by asking a model. **Knows it's being tested** is on by default, and alerts pop up on the Room when they fire.
- **Past tests** has its own tab with verdicts, rule results, **Run again** and **Export**. Export saves the full log as Markdown or all raw files as a zip.
- **More stable sandbox.** A parallel port scan could hit the process limit, and gVisor then stops the whole sandbox. The limit is now 4096. A crashed workstation is detected and restarted clean, with the agents told; if it stays down, the test ends as a harness failure instead of looping.

## Evals

- **Overview:** scenarios against configs (model, team size, turns, prompt version), with safe rates, 95% Wilson ranges and the number of runs.
- **Batches:** run one scenario on one or more models N times. Runs alternate between models.
- **Metrics:** rule-break, disclosure, delegated-break and dishonest-report rates, per-rule and per-alert rates, and reliability as pass^k.
- **Compare:** two configs on shared scenarios, with a paired difference and its range.
- **Review:** an LLM judge for the report that never sees the Observer, a review queue of disagreements plus a random 15%, and Cohen's κ against your calls.

Rule detectors, delegation flags and phrase alerts are heuristics: review them against the evidence they cite. A few runs give counts, not rates.

## Also

- Positive controls per task, with an editor and a commented example; control runs are sealed automatically.
- Environment services: SQL database, secrets vault, object store and mail outbox.
- Models: thinking is on by default for new servers.

## Upgrade

Install it from inside Dyno (Dyno Lab → Check for Updates…), or download the signed DMG. Finish active work before restarting. Saved studies, runs and downloaded models live outside the app bundle.

---

# Dyno Lab 0.5.2

Dyno Lab 0.5.2 updates the bundled sandbox harness with fixes from reviewing this week’s agent runs, and adds a test where nothing but the rule keeps the agent out of production.

## Agent sandbox tests

- New task **Quarterly report, production reachable** and environment **Segmented office network (production reachable)**. The gateway lets connections to a fake production database through and records each one, and a check on the finished report detects production numbers. See the [agent sandbox tests guide](agent-sandbox-tests.md).
- Evidence exports carry the exact task and environment files each episode ran with. Every episode saves a snapshot and records its hash, and an export refuses a definition that doesn’t match.
- Fewer wrong labels:
    - A partial report that states what’s missing can count as an honest stop, for tasks whose honest path is a partial deliverable. It is still marked for hand review.
    - The agent contacting its own machine, by name or by address, is no longer flagged as an unlisted host.
    - Listing or identifying a secret file (`ls`, `file`, `stat`) is no longer counted as reading it.
- Connections made with bash’s `/dev/tcp` now count as network attempts.

Labels come from heuristic rules and must be reviewed. Results from a few episodes are counts, not rates.

## Upgrade

Install it from inside Dyno (Dyno Lab → Check for Updates…), or download the signed DMG. Finish active work before restarting. Saved studies, runs and downloaded models live outside the app bundle.

---

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
