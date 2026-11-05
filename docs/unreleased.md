# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Browser

- **A browser the model can use.** The new **Browser** tab is a web browser that models with **Web access** drive, like Opera's browser agent: they open pages, read them as text and numbered links, buttons and fields, and, if you allow it, click and type. Choose **Read only** (the default), **Ask before submitting** (Dyno asks you before anything that submits, buys, sends, posts or deletes) or **Full control**. It never types passwords or card details, keeps its own cookies and logins, opens public pages only, and lists every step; **Pause the model** lets you take over.

## Models

- **GGUF models on this Mac.** **Models → GGUF** now lists your downloaded GGUF files with the same **Start** panel as MLX models. Dyno runs them with the llama.cpp build in the app, on the GPU, behind its own endpoint, so Chat, Claude Code and Codex (`dyno launch`), Web access, the Browser, the Observer and Performance work with them too. From the terminal: `dyno serve --model file.gguf`. Before, GGUF files could only run in Pools.
- **Web access.** A new **Web access** switch beside Start (`dyno serve --web`) lets apps that chat with a served model, such as chat apps that bring no tools of their own, search the web and read pages. Dyno gives the model `web_search` and `read_page`, runs them on this Mac with the search from Settings → Web search, and the app gets the finished answer. Pages on this Mac and your local network can't be read. Each search and page read shows in Performance → Logs. Off by default. Claude's web fetch tool is now answered the same way as its web search.
