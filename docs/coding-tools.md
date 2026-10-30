# Claude Code and Codex on your own models

Run [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) or [Codex](https://github.com/openai/codex) on a model you've downloaded in Dyno. The model answers on your Mac instead of Anthropic's or OpenAI's servers. The tools themselves may still contact their makers for sign-in, updates or usage data, depending on how you've set them up; `dyno launch` turns off Claude Code's optional traffic.

```
dyno launch claude --model qwen3.8-27b
dyno launch codex --model qwen3.8-27b
```

Dyno's model server speaks each tool's own API, so there's no proxy to install and no config file to edit.

## Before you start

1. **A model.** Download one in **Discover**. A 27B model or larger works best: we tested Qwen3.8-27B (MLX, 4-bit). An 8B model answers simple questions and uses the tools, but it gets lost on multi-step tasks.
2. **The tool.** Install it if you haven't:
    - Claude Code: `npm install -g @anthropic-ai/claude-code`
    - Codex: `npm install -g @openai/codex`
3. **The `dyno` command.** Dyno adds it when you open the app, so it works in a new Terminal window. If you have Homebrew, it goes in `/opt/homebrew/bin` with no password. Otherwise Dyno asks once to add `/usr/local/bin/dyno`, and macOS asks for your password; choose **Not Now** and you can do it later in **Router → Install the dyno command…**. If you move or update Dyno, the command follows it. Dyno never replaces another program called `dyno`. If you installed Dyno's Python package with pip, you already have the command.

The **Router** tab shows these commands for the model you pick, with a **Copy** button for each.

## Run it

```
dyno models
```

This lists the models you've downloaded, with their size, context window and the port serving them, if any.

```
dyno launch claude --model qwen3.8-27b
```

`--model` takes the model's full name (`lmstudio-community/Qwen3.8-27B-MLX-4bit`) or any part of it that matches only one model. Dyno tells you if a name matches several.

`dyno launch` then:

1. **Uses the model if it's already running** in a Dyno server, or starts it on a free port between 8970 and 8979, in [serve-only mode](#speed-serve-only-mode). Loading takes a moment. It then says whether speculative decoding is on, and if not, why.
2. **Starts the tool pointed at it.** Every model the tool would use, including Claude Code's background model and subagents, is the one you chose. The tool's context window is set to the model's own.
3. **Stops the model it started** when you quit the tool, or close the terminal. Add `--keep` to leave it running.

Anything after `--` goes to the tool:

```
dyno launch claude --model qwen3.8-27b -- -p "The tests fail. Fix them."
dyno launch codex --model qwen3.8-27b -- exec "The tests fail. Fix them."
```

## Speed: serve-only mode

A Dyno model server runs in one of two modes:

- **Research** (the default in **Models**) keeps every Dyno feature on: the Observer's request history, activation capture while serving, any number of requests at once.
- **Serve only** is for Claude Code, Codex and other apps. It answers one request at a time on the fastest path, with speculative decoding when the model has a drafter, and turns the research features off. `dyno launch` starts servers this way. In **Models**, choose **Use: Serve only** before **Start**. From a terminal: `dyno serve --model … --mode serve`.

What makes Claude Code fast or slow on your own model, measured with Qwen3.8-27B 4-bit on an M5 Max:

| | Reply speed | Each later turn starts after |
|---|---|---|
| No drafter, several requests at once (what `dyno launch` did before) | 20 tok/s | 1–3 s |
| DFlash2 drafter, before this change | 50–100 tok/s | 21 s (the whole prompt read again) |
| **Serve only with the DFlash2 drafter** | **45–120 tok/s** | **0.6–2.3 s** |

- **Get a draft model.** Speculative decoding is where the speed comes from: a small draft model proposes several tokens and the model checks them in one step, with the same output. For Qwen3.8-27B, click **Speculative decoding** next to the model in Models or Discover (or search Discover for "dflash"), or run `dyno pull z-lab/Qwen3.8-27B-DFlash2` (the fastest). You never start the draft model yourself: the model uses it once it is downloaded. Without it, Dyno uses the model's own MTP head, which it downloads once (~0.85 GB). If neither is available, `dyno launch` says why.
- **Each turn reads only what's new.** Serve only saves the prompt cache at the end of the system prompt and at the start of each reply. The next turn, and a new session with the same tools, starts from there instead of reading Claude Code's ~12,000-token instructions again.
- **Thinking.** Qwen3.x thinks before answering by default. That's better on hard tasks but slower. `dyno launch claude --model … --thinking off` starts the server without it.
- **Is it working or stuck?** Open **Performance → Logs**. It shows what the server is doing now: reading Claude Code's prompt (tokens read, speed and time left), generating (tokens and tok/s), or nothing for a while. Below that is the server's whole log. The first prompt is the slow one: about 20,000 tokens to read, a minute on an M5 Max and longer on earlier Macs. From a terminal, `tail -f ~/.mlx-dyno/logs/launch-*.log` shows the same lines for a `dyno launch` server.
- **A server you started in Models** in research mode is used as it is. `dyno launch` says so; restart it with **Use: Serve only** for full speed.

### Permissions: skipping the prompts, and why auto mode doesn't work

Claude Code asks before it runs a command or edits a file. To let it work without asking:

```
dyno launch claude --model qwen3.8-27b -- --dangerously-skip-permissions
```

Every command and edit then runs straight away, so start it in a git worktree or a throwaway copy of your project, not in a folder with work you can't lose. A local model makes more mistakes than Claude does, and nothing stops a wrong `rm` or `git reset`. Claude Code refuses this mode when run as root or with `sudo`. To keep asking but accept file edits without a prompt, press Shift+Tab in Claude Code to switch to *accept edits*.

**Auto mode doesn't work with your own model.** Claude Code's [auto mode](https://code.claude.com/docs/en/permission-modes.md) approves safe actions on its own. It does that by sending each action it isn't sure about to a separate classifier model, and that classifier must be a Claude model: auto mode is [supported](https://code.claude.com/docs/en/auto-mode-config.md) only on Claude models. On a model served by Dyno it is either not offered in the Shift+Tab cycle, or its checks fail and Claude Code denies every action it checks. Use the normal prompts, *accept edits*, or the command above.

What we saw with Qwen3.8-27B on an M5 Max: given a small project with a failing test, Claude Code ran the test, found the bug, fixed it and reran the test in 74 seconds, including loading the model. Codex did the same in 52 seconds.

## Web search

Both tools can search the web while they run on your model. Claude Code's **WebSearch** and Codex's web search normally run on Anthropic's or OpenAI's servers. With Dyno, Dyno runs them:

- The model gets a search tool. When it searches, Dyno runs the search, gives the model the results, and the tool shows the search as usual.
- Dyno searches with **SearXNG** in Docker on your Mac (free), or with a paid search API you choose in **Settings → Web search**: Brave, Tavily, Exa or Serper. A paid API needs a key; Dyno keeps it in your macOS Keychain. **Test** runs one search so you can check it works.
- Claude Code's allowed and blocked domains are applied to the results.

Search queries leave your Mac: they go to the search engines (SearXNG) or to the provider you chose. See [Dyno's assistant](assistant.md#web-search-optional) for what that means.

## Without `dyno launch`

Any Dyno model server (`dyno serve`, or a model started in **Models**) answers both APIs, on the same port as its OpenAI API:

| API | Path | Used by |
|---|---|---|
| Anthropic Messages | `/v1/messages`, `/v1/messages/count_tokens` | Claude Code, Anthropic SDKs |
| OpenAI Responses | `/v1/responses` | Codex, OpenAI SDKs |
| OpenAI Chat Completions | `/v1/chat/completions` | everything else |

To point Claude Code at a model running on port 8971 yourself:

```
ANTHROPIC_BASE_URL=http://127.0.0.1:8971 ANTHROPIC_AUTH_TOKEN=dyno claude --model Qwen3.8-27B-MLX-4bit
```

And Codex:

```
codex -c model_provider=dyno -c 'model_providers.dyno.name="Dyno"' \
  -c 'model_providers.dyno.base_url="http://127.0.0.1:8971/v1"' \
  -c 'model_providers.dyno.wire_api="responses"' -m Qwen3.8-27B-MLX-4bit
```

The model name can be anything the server doesn't list (Claude Code asks for `claude-…` names): the server then uses the model it's serving, and never downloads one.

## Limits

- **Your model, not Claude or GPT.** The tools work, but a local model makes more mistakes with them, especially on long tasks.
- **Not translated:** Anthropic's and OpenAI's other hosted tools (code execution, file search), PDFs, and your MCP servers in Codex, which Codex only offers to OpenAI's models. Claude Code's MCP servers work: they're ordinary tools.
- **The first reply is slow.** Before it answers, the model reads the tool's instructions, about 16,000 to 24,000 tokens. That took 75 seconds on an M5 Max and over 5 minutes on a slower Mac. Later replies read only what's new, and so does a new session while the model is still loaded: about 3,000 tokens instead of 16,000, in any folder. So keep the model loaded between sessions: start it in **Models**, or add `--keep` to `dyno launch`. Dyno keeps the connection alive meanwhile, and `dyno launch` raises the tools' timeouts to an hour (`API_TIMEOUT_MS` for Claude Code). If you point Claude Code at Dyno yourself, set `API_TIMEOUT_MS=3600000` too. A smaller model reads faster.
- **Token counts are estimates** (about four characters a token). Claude Code uses them to decide when to compact a conversation.
- **Only this Mac.** The APIs answer programs on this Mac and refuse web pages, so a site you visit can't use your model through them.
- A model started in Dyno before 0.6.9 doesn't have these APIs. `dyno launch` then starts another copy of the model and says so; restart the model in **Models** to avoid that.
