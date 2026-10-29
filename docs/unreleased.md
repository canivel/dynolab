# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Assistant

- **New chat.** A pencil button in the assistant's header (⇧⌘N) clears the chat and starts a fresh one. The previous conversation stays in the list under the title; if the assistant was working, it stops first.
- **Answers instead of stopping mid-research.** The assistant can take 30 steps per message instead of 12 (each web search or page read is one). If it still runs out, it answers with what it found and what's left, rather than stopping with only a warning.
- **Chats survive restarts.** A conversation cut off by quitting Dyno no longer stays "thinking" forever, and the assistant now waits for Dyno's lab service at launch, so the conversation list is no longer empty and the open chat is no longer forgotten.
- **Connectors (MCP servers).** Add MCP servers in the new **Settings → Connectors** (a command on this Mac or a remote URL, or paste a Claude Desktop / Claude Code config), then turn them on per conversation from the new **+** menu in the composer. Tools that change something wait for your approval; read-only tools can run without asking if you allow it. Tokens go to the Keychain.
- **A + menu in the composer.** Files, web search and connectors are all under **+**, and what's on shows as chips above the message box.

## Claude Code and Codex

- **No-prompts command.** Router → *Use with Claude Code or Codex* now shows `dyno launch claude --model … -- --dangerously-skip-permissions` with a Copy button. The guide explains when to use it, and why Claude Code's auto mode doesn't work with local models (it needs a Claude model to check each action).
