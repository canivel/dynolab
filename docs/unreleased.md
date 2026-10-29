# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Assistant

- **New chat.** A pencil button in the assistant's header (⇧⌘N) clears the chat and starts a fresh one. The previous conversation stays in the list under the title; if the assistant was working, it stops first.
- **Answers instead of stopping mid-research.** The assistant can take 30 steps per message instead of 12 (each web search or page read is one). If it still runs out, it answers with what it found and what's left, rather than stopping with only a warning.
- **Chats survive restarts.** A conversation cut off by quitting Dyno no longer stays "thinking" forever, and the assistant now waits for Dyno's lab service at launch, so the conversation list is no longer empty and the open chat is no longer forgotten.
