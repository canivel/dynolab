# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Models

- **Web access.** A new **Web access** switch beside Start (`dyno serve --web`) lets apps that chat with a served model, such as chat apps that bring no tools of their own, search the web and read pages. Dyno gives the model `web_search` and `read_page`, runs them on this Mac with the search from Settings → Web search, and the app gets the finished answer. Pages on this Mac and your local network can't be read. Each search and page read shows in Performance → Logs. Off by default. Claude's web fetch tool is now answered the same way as its web search.
