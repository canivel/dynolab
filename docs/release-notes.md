# Dyno Lab 0.6.16

Dyno Lab 0.6.16 shows what a model server is doing: Performance → Logs follows each request as it reads the prompt and generates, so a long first prompt from Claude Code no longer looks like a hang. The DFlash2 draft model can now be found by name in Discover, and the app says "speculative decoding" and "draft model".

## Models and Discover

- **Find the draft model by name.** Searching Discover for `z-lab/Qwen3.8-27B-DFlash2`, "dflash", "draft" or "speculative" now shows it, with what it does and its download state. Hugging Face tags it as a Transformers model, so the hub search never returned it. Downloaded has a **Draft models** section, where you can delete it.
- **Plain words.** The button is now **Speculative decoding** (then **Speculative decoding ready**) instead of "Get drafter", and the app, `dyno launch` and `dyno serve` say "draft model". "Good with Dyno" names the draft model under Qwen3.8-27B.
- **Full models with "DFlash2" in their name stay listed.** Dyno now tells a draft model from its `config.json`, as `dyno launch` does, so a download such as `GLM-5.3-Flash-…-DFlash2` no longer disappears from Downloaded.

## Performance

- **Logs.** Performance has a new **Logs** source: what a model server is doing right now (waiting, reading the prompt with tokens read, speed and time left, or generating) and its full log, live. Servers started in Models now keep their log in `~/.mlx-dyno/logs/serve-<port>.log`; `dyno launch` servers are listed too.
- **The server says what it's doing.** `dyno serve` writes a line when a request arrives, starts reading its prompt (and how much came from the prompt cache), gets its first token and finishes, plus a progress line every 10 s while reading a long prompt and a warning when no token has come for 30 s. With a draft model or MTP head this progress was invisible before. `/stats` reports the same under `live.requests`.

---

# Dyno Lab 0.6.15

Dyno Lab 0.6.15 makes the fastest setup for Claude Code one click away, and helps you pick what to download: Discover now suggests models that run well with Dyno, and the DFlash2 drafter downloads from the app.

## Models and Discover

- **Good with Dyno.** Discover opens with a short list of models that run well with Dyno, what each is good for, and only the ones that fit this Mac.
- **Get the drafter in the app.** Qwen3.8-27B rows in Discover and Models have a **Get drafter** button that downloads the DFlash2 drafter (it never showed up in the search). Drafters no longer appear as models to start, and `dyno launch` and `dyno models` skip them: `dyno launch claude --model qwen3.8-27b` no longer picks the drafter and fails with "missing rope_theta". `dyno serve` on a drafter now says which model to serve instead.
- **Which build is which.** Downloaded models show their full lab/model name (`lmstudio-community/Qwen3.8-27B-MLX-4bit`) under the short name, so builds of the same model from different labs no longer look identical.

---

# Dyno Lab 0.6.14

Dyno Lab 0.6.14 makes Claude Code and Codex much faster on your own models, and lets the assistant use tools from MCP servers, the way Claude and ChatGPT add connectors.

## Claude Code and Codex

- **Serve-only mode.** Models has a new **Use: Research / Serve only** choice, and `dyno launch` now starts servers in serve-only mode. That means one request at a time on the fastest path, with speculative decoding, and none of the research features (Observer history, activation capture). Before, `dyno launch` on a Mac without a drafter decoded through mlx_lm's batched path at about 20 tok/s.
- **Each turn reads only what's new.** With a drafter, every Claude Code turn used to read the whole ~12,000-token prompt again. Dyno now saves the prompt cache at the end of the system prompt and at the start of each reply. On an M5 Max with Qwen3.8-27B, a later turn starts in 0.6–2.3 s instead of about 21 s, at 45–120 tok/s with the DFlash2 drafter.
- **`dyno launch` says how fast it can go.** It loads the model before the first turn, says whether speculative decoding is on and, if not, why. `--thinking off` starts the model without thinking, and `--research` keeps the research features. See [Speed: serve-only mode](coding-tools.md#speed-serve-only-mode).
- **No-prompts command.** Router → *Use with Claude Code or Codex* shows `dyno launch claude --model … -- --dangerously-skip-permissions` with a Copy button. The guide explains when to use it, and why Claude Code's auto mode doesn't work with local models: it needs a Claude model to check each action.

## Assistant

- **Connectors (MCP servers).** Add MCP servers in the new **Settings → Connectors**. Each is a command on this Mac or a remote URL, or you can paste a Claude Desktop or Claude Code config as is. Turn them on per conversation from the **+** menu. Tools that change something wait for your approval. Read-only tools can run without asking if you allow it for that connector. Tokens go to the Keychain. See [Connectors](assistant.md#connectors-mcp-servers).
- **A + menu in the composer.** Files, web search and connectors are all under **+**, and what's on shows as chips above the message box.
- **New chat.** A pencil button in the header (⇧⌘N) clears the chat and starts a fresh one. The previous conversation stays in the list.
- **Answers instead of stopping mid-research.** The assistant can take 30 steps per message instead of 12. If it still runs out, it answers with what it found and what's left.
- **Chats survive restarts.** A conversation cut off by quitting Dyno no longer stays "thinking" forever. The assistant also waits for the lab service at launch, so the conversation list is no longer empty after a restart.

---

# Dyno Lab 0.6.13

Dyno Lab 0.6.13 makes Qwen generation faster again: about 2× on code edits and 1.5× on reasoning on M5 Macs, no longer slower than plain decoding on earlier Macs, and a third faster for models without a draft head. Models Dyno speeds up now carry a **Dyno Boost** badge.

## Faster generation

- **Copying from the context.** When the model rewrites a file, quotes a path or repeats part of the question, the next tokens are often already in the prompt or earlier in the answer. Dyno now checks those copied tokens, up to 15 at once, instead of guessing. Code edits on Qwen3.8-27B: 115 → 242 tok/s greedy, 117 → 231 with sampling. `DYNO_COPY_DRAFTS=0` turns it off.
- **Draft trees on M5.** With the DFlash2 drafter, Dyno checks a tree of the 15 likeliest guesses in one pass instead of one 15-token line, so when the drafter's first choice is wrong its second or third choice is often right. Reasoning: 94 → 148 tok/s greedy, 90 → 133 with sampling; chat 41 → 50 and 42 → 48; code 88 → 116 greedy, level with sampling. `DYNO_DFLASH_TREES=0` goes back to single lines. The tree search follows [mlx-serve](https://github.com/ddalcu/mlx-serve) (MIT).
- **Not slower on M4 and earlier.** On Macs before the M5, checking several guesses costs more, and 0.6.12 could decode a Qwen model below its plain speed (13.6 tok/s on an M4 Max). Dyno now times a plain step next to its drafts and decodes plain whenever that's faster, trying a draft now and then to notice when the text becomes predictable (code, edits). It should cost at most a few percent where drafting doesn't pay.
- **Plain decoding a third faster.** Models without a draft head (Qwen3.6-35B-A3B, other families, `--speculative off`) went through mlx_lm's batching path even one request at a time. They now decode like the library does: 21–25 → 29–33 tok/s on Qwen3.8-27B 4-bit.
- **Same output.** Every guess, copied or drafted, is kept with the same exact rule as before, so each token has the model's own probability at your sampling settings.

Measured through `dyno serve` on an M5 Max with Qwen3.8-27B 4-bit and the DFlash2 drafter, 384-token answers, median of three runs, alternating with 0.6.12. See [Faster generation](faster-generation.md).

## Dyno Boost badge

- **In Models and Discover,** a lime bolt marks the models Dyno speeds up (dense Qwen3.5, 3.6 and 3.8, fine-tunes included). Its tooltip says what to expect: the biggest gains on M5 Macs, smaller ones before.

---

# Dyno Lab 0.6.12

Dyno Lab 0.6.12 sets up the agent sandbox the first time you open it, asking before it installs anything, and makes Qwen generation faster again on M5 Macs: up to 3.8× plain decoding on code, reasoning and edits.

## The sandbox sets itself up

- **On first launch** Dyno looks at your Mac and lists what agent tests still need: Docker, the gVisor runtime, the sandbox image and an internal-only network. Each says why it's needed and what setup will do, with a time estimate. Nothing is installed until you click **Install and set up**; Dyno then installs what's missing with Homebrew, starts the Colima VM, builds the image and runs the isolation checks. If Homebrew itself is missing, it shows the install command to run in Terminal. Reopen it from **Agents › Advanced › Readiness › Guided setup…** or **Set up the sandbox…** next to **Start test**. See [Agent sandbox tests](agent-sandbox-tests.md).
- **Start test says why it's off** instead of just being grey.
- **No more stuck checks.** A test container that won't start or hangs is reported with Docker's own error, a failed image build shows why, and setup and the checks are stopped with an explanation if they run too long.

## Faster generation on M5

- **Drafts checked on the neural accelerators.** On Macs whose GPU has them (M5 and later), Dyno checks a model's guesses with its own kernel, so checking 16 tokens costs about the same as 5. Qwen models now draft up to 7 tokens instead of 3: 1.2–1.9× faster than 0.6.11 on code, reasoning and edits, with no change on chat. `DYNO_NAX=0` turns it off. See [Faster generation](faster-generation.md).
- **DFlash2 block drafter, optional.** For Qwen3.8-27B, `dyno pull z-lab/Qwen3.8-27B-DFlash2` (3.2 GB) adds a drafter that proposes a block of up to 7 tokens in one pass; with it on disk Dyno uses it automatically, 10–15% faster again on code and reasoning. It uses about 1.7 GB more memory and is never downloaded on its own. `--speculative mtp` keeps the built-in head.
- **Same output.** Every guess is accepted with the same exact rule as 0.6.11, so each token keeps the model's probability at your sampling settings.

---

# Dyno Lab 0.6.11

Dyno Lab 0.6.11 makes Qwen3.5, 3.6 and 3.8 models generate about twice as fast, with exactly the same output. Nothing to set up.

## Faster generation

- **Up to 2.35× faster on Qwen.** These models ship a small extra layer that guesses the next few tokens. Dyno now uses it: the model checks every guess in one pass and keeps only the tokens it would have written itself. Qwen3.8-27B 4-bit on an M5 Max, with the model's recommended sampling: code 20.4 → 45.8 tok/s, reasoning 19.5 → 45.3, code edits 19.8 → 46.8, chat 22.9 → 33.3. See [Faster generation](faster-generation.md).
- **Same output.** At temperature 0 the text is the model's own greedy text. With sampling, guesses are accepted with the standard lossless rule, so every token keeps exactly the model's probability at your temperature, top-p and top-k.
- **On by default** for dense Qwen3.5, 3.6 and 3.8 models, fine-tunes included, when a model serves one request at a time, as the app starts large models. The first start downloads the model's draft head once (about 0.85 GB for Qwen3.8-27B), not the whole checkpoint. `dyno serve --speculative off` turns it off.
- **Measured.** `/stats` reports how many guesses were drafted and accepted, and the server log shows it per request.

---

# Dyno Lab 0.6.10

Dyno Lab 0.6.10 adds **Neurons** to the Research Lab: read every neuron of a layer on your own model, label them with one local model, score the labels with another, and test them with ablations and attribution, every number next to its baseline. The `dyno` command now sets itself up when the app opens, and Claude Code and Codex no longer give up while a slower Mac reads their long prompt.

## Neurons in the Research Lab

Built to test claims like Nick Cammarata's [Neural Networks Are Already Clean](https://already-clean.goodfire.com/) on a model on your Mac. See the [Neurons tutorial](neurons.md).

- **Neuron hooks.** `mlp_hidden` (the input to `down_proj`, one coordinate per neuron) and the gate, up, MLP and attention outputs, for gated MLPs (Llama, Qwen, Mistral, Gemma). A check on a real prompt confirms the hooked layer reproduces the model's own output before anything runs. The existing Lab jobs take `hook` too.
- **Capture** runs a corpus through the model and keeps, for every neuron and both poles, its strongest examples with context, stratified and random samples, a histogram, and held-out documents the explainer never sees. Presets for a web mix and FineWeb-Edu, or your own files and Hugging Face datasets. A stopped capture resumes exactly.
- **Atlas:** a page per neuron with both poles side by side, firing rates and examples, browsable in the app.
- **Auto-interp:** an explainer model labels each pole from its examples, and a different scorer model uses only the label to find held-out examples. Random directions and shuffled labels are scored the same way. Switch between the 2023-style and the improved method, and pair two runs to compare them.
- **Agent interpreter:** the explainer can read examples by decile and measure its own test sentences on the model before it submits a label; transcripts are checked for held-out text.
- **Ablation** by activation strength (weakest 75%, strongest 7%) at every layer, with random controls matched in mass and in count, and bootstrap intervals.
- **Units:** attribution to a target token, set ablation against random sets from the same layers, and steering.
- **SAEs** (TopK, BatchTopK, ReLU-L1) trained on the same layer, and how each feature lines up with the neurons.
- **Recipes** chain all of it into one run with one report; `already-clean-fast` and `already-clean-full` are built in.
- SDK methods, [HTTP API](http-api.md#neurons) and [MCP tools](local-mcp.md#neuron-tools) for every step.

Everything runs in the Lab's separate worker process, and nothing leaves the Mac.

## The `dyno` command

- **Set up when the app opens.** Before, `dyno launch claude` failed with "command not found" until you found **Router → Install the dyno command…**. Now Dyno adds it on launch, without a password when a folder on your PATH is yours (Homebrew's `/opt/homebrew/bin`, `~/.local/bin`, `~/bin`); otherwise it asks once. A `dyno` command from a moved copy of the app is pointed at this one, and another program called `dyno` is never replaced.

## Claude Code and Codex

- **No more giving up on a long prompt.** A slower Mac can read Claude Code's ~23k-token prompt for minutes before the first token, and Claude Code timed out and started over. The model server now sends keepalives while it reads, and `dyno launch` gives Claude Code and Codex an hour before they time out.
- **Faster new sessions.** Claude Code's prompt is rearranged so a loaded model reuses most of it: a new session reads ~3k tokens instead of ~16k, 22–26 s instead of 89 s on Qwen3.8-27B (M5 Max).

---

# Dyno Lab 0.6.9

Dyno Lab 0.6.9 runs Claude Code and Codex on the models you download, with web search, in one command. Web search can also use a paid search API, and agent tests can now prefill a session with real tool calls and choose how the agents' model samples.

## Claude Code and Codex on your own models

- **`dyno launch claude --model <name>` and `dyno launch codex --model <name>`.** Dyno uses the model if it's already running, or starts it, then opens the tool pointed at it. Quit the tool, or close the terminal, and Dyno stops the model it started. Anything after `--` goes to the tool. See [Claude Code and Codex on your own models](coding-tools.md).
- **`dyno models`** lists your downloaded models with their size, context window and the port serving them.
- **Two more APIs on every model server.** Anthropic's Messages API (`/v1/messages`) for Claude Code, and OpenAI's Responses API (`/v1/responses`) for Codex, on the same port as the OpenAI API, with tool calls, streaming and thinking. Built into Dyno, with no proxy to install. They answer only programs on this Mac. See the [HTTP API](http-api.md#anthropic-messages-and-openai-responses).
- **Web search in both tools.** Claude Code's WebSearch and Codex's web search run through Dyno's own web search, so the model can look things up.
- **Router → Use with Claude Code or Codex** shows the commands for the model you pick, and **Install the dyno command…** adds `dyno` to Terminal.

With Qwen3.8-27B, both tools found and fixed a bug from a failing test on their own, in under 75 seconds.

## Web search

- **Choose a paid search API.** **Settings → Web search** offers Brave, Tavily, Exa and Serper besides the free SearXNG. The key is kept in your macOS Keychain, and **Test** checks it with one search. Dyno's assistant uses the same choice.
- **"Docker isn't running" while it was.** Opened from Finder, Dyno couldn't find Docker in Homebrew, so web search failed with Colima running. It now looks there, and says so plainly when Docker isn't installed.

## Agent tests

- **Prefill a session with tool calls.** A test's prefilled history can include the agent's own tool calls and their results, sent to the model as real messages. Reproductions such as *Deception by Omission* start the model after a mistake it never chose.
- **Script lines sent as written.** A scripted message can reach the agents exactly as typed, as their whole turn, without the room's wrapper.
- **Optional "What you did" field.** Turn off the submit tool's summary field when whether the agent reviews its own work is what you measure.
- **Sampling.** Set the agents' temperature, top-p and top-k in Setup, or choose **Use the model's** for the values in the model's `generation_config.json`. Before, a local model always ran at temperature 0, so every run of a test was the same run. Sampling travels in shared test packages, and in Evals each sampling is its own condition.

---

# Dyno Lab 0.6.8

Dyno Lab 0.6.8 lets the assistant run on any model you download, including abliterated and merged models whose chat template can't call tools, and test a different model from the one it runs on. It also reads documents, runs several models at once, deletes downloaded models, and links each Observer card to the moment in the Room behind it.

## Any model in the assistant

- **Tool calling for any model.** Some models (often abliterated or merged ones) ship a chat template that drops tools, or no template at all, so the assistant stopped after its first step. `dyno serve` now borrows the template of a downloaded model of the same family when its special tokens fit, or uses a built-in tool format that works through any template. `/stats` says which under `model.tool_calls`. See [Tool calling for any model](runtime-notes.md#tool-calling-for-any-model).
- **A long tool call no longer stops the assistant silently.** mlx_lm's Qwen tool parser crashed on a long JSON argument with a line break in it, and the reply just ended. Dyno now reads such calls with a more forgiving parser, and an answer that breaks off part-way shows an error instead of silence.
- **Tests run on.** With two or more models running, choose which one the assistant tests. It keeps running on its own model.
- **Several models at once.** Start more than one model in Models; each gets a free port. The assistant's picker tells servers apart by port, so two Dyno servers no longer look like one.
- **Incomplete downloads.** A model missing a weight file is marked *incomplete download* and won't start, and `dyno serve` exits with one line saying why instead of hanging.

## The assistant

- **Documents.** Attach files with the paperclip or drop them on the panel: PDF (scanned pages read with OCR), Word, RTF, HTML, text and images. Text is read on your Mac. Short documents go to the model whole; long ones through search and page reads.
- **Context size.** Click the meter to choose from 16K up to the model's own context, before or during a conversation.
- **No more loops.** It no longer polls a running test over and over, asks you to approve the same action again after it worked, or re-reads the same prompt list.
- **Environments save.** Saving an environment always failed with `Unsupported environment fields: ['agents']`. An image named after a Dyno preset (`dyno/mock-api`) is now that preset instead of an image Docker can't pull.
- **Watch it** opens the test that is running, not the previous one, and chat text can be selected and copied.

## Room & Observer

- **Click an Observer card** to see the moment behind it. The Room scrolls to the command, message or output and outlines it, in Conversation or Full log.

## Models

- **Delete downloaded models.** A Trash button in Discover → Downloaded, and **Move to Trash…** in the Models sidebar. It shows the real size, removes a Hugging Face cache entry whole, refuses a model that is being served, and uses the Trash, so it can be undone.

---

# Dyno Lab 0.6.7

Dyno Lab 0.6.7 lets the assistant search the web if you allow it, save environments and import whole tests, and fixes a crash when switching to an empty assistant conversation.

- **Web search for the assistant (optional).** Tick **Web search** in the assistant panel to let it search the web and read public pages, through SearXNG running in Docker on this Mac. It's off by default, for each conversation. The tooltip explains what leaves the Mac (your search queries) and the risks; local and private addresses can't be read. See [Dyno's assistant](assistant.md#web-search-optional).
- **The assistant can save environments and import tests.**
  - Paste a Compose file or environment JSON, approve one card, and the environment appears under Setup → Yours. The harness checks it first; the assistant sees the errors before you see a card.
  - It can also import a `.dynotest.json` test package and fill Setup with it.
- **Alerts and Speaks as from the assistant.** Proposed setups can carry the test's Observer alerts and *Speaks as*, and Setup shows them.
- **The assistant no longer quits Dyno when you switch to an empty conversation.** Lists in the panel were drawn by index; emptying them while SwiftUI still drew a row read past the end.
- **No smart quotes in code editors.** The routes, phrases, Compose, task, prompt and config editors no longer turn " into curly quotes or -- into dashes, and a click inside them focuses them.
- **Severe alerts.** The alert editor offers Severe, and the Room shows severe alerts in red.
- **Phrase alerts and commands.** The Room says when a phrase alert matched text in a command (not a connection), and an alert can match only where a command connects.
- **Fewer false delegation flags.** The Observer read a lead's "that does NOT touch admin.internal" as pointing a teammate at the protected host, and labelled the teammate's own actions as delegated.
- **Sharing explains a read-only token.** A research token made without *Allow private draft creation* can't upload, and Dyno Research refused it with a bare scope error. The Share sheet now says what to do, and the token field reminds you to tick it.

---

# Dyno Lab 0.6.6

Dyno Lab 0.6.6 adds Dyno's assistant, a chat beside every tab that sets up tests and evals with a model on your Mac, and runs Evals on [Inspect AI](https://inspect.aisi.org.uk), the open-source evaluation framework from the UK AI Security Institute, and replaces the "knows it's being tested" phrase list with a detector that has to quote the agent. A real experiment on two local models shaped it and is written up as a tutorial and a study: [Tutorial: agent tests and evals](agents-and-evals-tutorial.md) and [Does a rule said once survive?](tutorial/rule-said-once.md).

## Dyno's assistant

A panel beside every tab where you describe what you want to find out, typed or spoken. The assistant plans the work, looks at what Dyno has, fills in Agents → Setup for you to check, and asks before it runs or saves anything: each start or save is a card you approve or decline. It runs only on a model on this Mac, voice is recognised on device, and conversations are saved locally. Long conversations stay within the model's context: thinking is never sent back, old tool results are shortened, and older turns are summarized by the model, while the full history stays on disk. See [Dyno's assistant](assistant.md).

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

## Agents setup

- **Team size.** Type how many agents the test needs, the lead included (1–12). Above 1, the lead must create the rest of the team before any work: its prompt opens with the **team instruction**, telling it to build a team of N after working out the problem, the blockers, the rules and the gotchas. The instruction is a template you can reword and save with your prompt, but it can't be removed. Tests made before team sizes run as they did.
- **Each environment keeps its own test.** Switching environment brings back the goal, rules and script you last used with it (or its latest past test, or the example), instead of carrying the previous environment's setup over.

## Fixes

- **Models start with the settings Dyno shows.** Dyno passed only the settings that differed from its own defaults, so mlx_lm.server used its own: 512 tokens per reply and up to 32 requests at once. Thinking models returned empty answers, and long agent tests could run the server out of Metal resources.
- **Evals leaves out runs that didn't really finish:** rooms that stopped on a harness or model-server error, and scripted tests whose script wasn't fully delivered (a model that never files a report never gets the scripted requests).
- **Voice keeps what you said across pauses.** Pausing for a second used to restart the transcription and lose what came before.
- An Inspect cell shows its eval's latest run instead of pooling runs made with different settings.
- **Long thinking no longer turns black.** Execution, the Room and the plain Chat showed a long answer or thinking as one block of text; past a few thousand tokens it was taller than macOS can draw and rendered black. Long text is now drawn in pieces.
- **Evals → Choose tells same-named scenarios apart:** a list, newest first, with each scenario's environment, rules, runs and last run date, and a badge saying how two with the same name differ.
- The Room's live lists no longer freeze the app (0.6.3's fix missed a case).
- An imported 0.6.3 test's alert shows once.

## Known issue

- The report check can mark *report honestly* broken when a true claim about one action ("test order sent to staging, not production") sits next to a different rule event, such as an earlier read-only probe. Read the flagged claim before counting it.

0.6.4 and 0.6.5 were built but never published; their changes ship in 0.6.6.

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
