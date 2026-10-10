# Dyno's assistant

The assistant is the panel on the right of every tab. Tell it what you want to find out, typed or spoken, and it turns that into tests and evals in Dyno. It plans the work, looks at what Dyno already has, fills in the screens for you to check, and asks before it runs or saves anything.

![The assistant set up a test in Agents → Setup and is waiting for approval to run it on two models](https://dynolab.dev/assets/tutorial-064/21-assistant-sets-up-test.png)

*From [a real test, start to finish](https://dynolab.dev/admin-api-scenario.html).*

**It runs only on your Mac.**
- It talks to a model you started in **Models**, at `127.0.0.1`. There is no cloud model and no fallback to one.
- Voice uses macOS on-device speech recognition. If your Mac can't recognise your language on device, the mic says so and you type instead.
- Conversations are saved by the lab service under `~/.mlx-dyno/lab/assistant/`, one folder per conversation.

## Using it

- **Open, minimize, resize.** The **Assistant** button (⌘J) opens or minimizes the panel. Minimized, it's a thin rail that still shows when the assistant is working or waiting for you. Drag the panel's left edge to resize it.
- **Pick the model** at the top of the panel. A larger model plans better; a smaller one answers faster. Each conversation remembers its model.
- **Talk to it.** Return sends; Shift-Return starts a new line. The mic turns what you say into text as you speak; check it and send.
- **What it does on its own:**
  - looks at your screen, environments, past tests, the Evals board, prompts and Inspect benchmarks;
  - checks a test setup;
  - opens screens;
  - fills **Agents → Setup** with a proposed test (the card has **Show it** and **Undo**);
  - keeps a task list above the chat.
- **What it asks first:** starting a test, running an Evals batch, saving or running an Inspect eval, saving an agent prompt, saving an environment, and importing a test package. Each shows a card with what will happen. **Approve** runs it, **Decline** doesn't, and you can add a note either way. Writing a message instead of choosing counts as not approving. Only your click runs anything.
- **Environments and whole tests.**
  - Paste a Compose file or environment JSON into the chat and ask the assistant to save it. It reads the text from your message, the harness checks it, and errors come back to the assistant before you see anything. You approve one card, and the environment appears in **Agents → Setup** under **Yours**.
  - It can also import a whole test from a `.dynotest.json` package, from a file in your home folder or a research.dynolab.dev link, and fill **Setup** with it.
- **Alerts and Speaks as.** A setup the assistant proposes can include the test's own Observer alerts and who speaks the rules said once and the script messages (*Speaks as*). Both appear in **Setup** and are used in the run.
- **Documents.** Click the paperclip, or drop files on the panel, to give the assistant PDFs, Word, RTF, OpenDocument, HTML, Markdown, plain text or code files, or images. See [Documents](#documents).
- **Selecting text.** Drag over any message, thinking or card text to select it; ⌘C copies and ⌘A selects a whole message.
- **Conversations** are in the title menu: new, open, rename, delete. **Plain chat with a model** opens the old full-window chat.

## Web search (optional)

Tick **Web search** under the model menu to let the assistant search the web and read pages in that conversation. It's off by default, for each conversation.

**How it works:**
- Dyno runs [SearXNG](https://github.com/searxng/searxng), an open-source search engine, in Docker on your Mac. It listens only on `127.0.0.1`. The first time you tick the box, Docker downloads it (about 100 MB).
- The assistant gets two more tools: one searches the web and returns titles, links and short excerpts; the other reads the text of a public page.
- Each search and each page read shows in the chat, for example *Searched the web: …* and *Read arxiv.org*.

**What leaves your Mac:**
- **Your search queries.** SearXNG sends them to Google, Bing and other search engines from your internet address.
- **Requests for the pages it reads,** sent to those websites the same way.

The model, your conversations, tests and files stay on your Mac.

**The risks, and what Dyno does about them:**
- **Prompt injection.** Web pages are written by other people and can contain instructions meant to mislead the assistant. Its instructions say to treat pages only as information, and it still can't run or save anything without your **Approve**.
- **Your own Mac and network.** Only public web addresses can be read; local and private addresses are refused, including after a redirect. So a page can't steer the assistant into Dyno's own services or your local network.
- **Search engines see your queries.** If that matters for a conversation, leave the box unticked.

SearXNG stops when Dyno quits.

## Documents

Click the paperclip next to the mic, or drop files anywhere on the panel.

- **Read on your Mac.** Dyno reads the text on your Mac: PDFs page by page, Word, RTF, OpenDocument and HTML files, and plain text such as Markdown, CSV, JSON or code. Scanned PDF pages and images are read with macOS's on-device text recognition (OCR), and the card says how many pages were read that way, since OCR can misread words. Nothing is uploaded.
- **Kept with the conversation.** The text is saved in the conversation's folder. A card in the chat shows the name, pages and size.
- **How the assistant reads it.** A short document (up to about 4,000 tokens) goes to the assistant whole, with your next message. A longer one is read when needed. The assistant gets three tools: list the documents, read from a page on, and search for a passage. A read takes as many pages as fit in about a quarter of the context size; search ranks passages by how many of the words they contain. The chat shows each step, for example *Read doc-1 from page 31*.
- **Documents are information, not instructions.** The assistant is told that instructions written inside a document don't change what it does. It still can't run or save anything without your **Approve**.
- **Limits.** Files up to 200 MB, up to 5,000 pages and 8 million characters of text. Password-protected PDFs can't be read.

## The context window

A model can only read so much at once. A long conversation is kept small for the model without losing anything on disk:

- **On disk:** each conversation is an append-only log, never shortened.
- **Sent to the model on each turn:** the instructions, the task list and your current screen, always. Then the recent turns.
- **Left out:** the model's own thinking is never sent back. Tool results older than the last two messages become a one-line note, and the model can look again if it needs to.
- **Size:** 32K tokens by default. Click the meter at the top of the panel (or open the settings menu next to it) to choose 16K, 32K, 64K, 128K or 256K, or **Full context** with the model's own maximum, for example 40K for Qwen3-8B. Sizes the chosen model can't read are greyed out. You can choose a size before the first message. Dyno reads each model's maximum from its downloaded config, and never sends a model more than that, even if the conversation's size is bigger. A bigger size keeps more of the conversation and documents word for word, but each answer starts more slowly and uses more memory.
- **Summarized:** when a conversation nears its size, the model writes a running summary of the older turns. The summary is saved in the log, and the last four turns always stay in full. A grey line in the chat marks where turns were summarized; click it to read the summary.
- **Measured:** token counts are estimated from characters and corrected with the counts the model server reports. The meter at the top shows how much of the budget the conversation uses.
- **Reopening:** a long conversation loads its last 60 messages, with **Load earlier messages** for the rest. Reopening costs the summary plus the recent turns, not the whole history.

## API

The lab service at `http://127.0.0.1:8980/lab/v1`:

| Method | Path | What |
|---|---|---|
| GET | `/assistant/conversations` | Conversations, newest first |
| POST | `/assistant/conversations` | A new conversation `{}` |
| GET | `/assistant/conversations/{id}?after=&before=&limit=` | Events, the reply being written (`live`), the task list, a waiting `pending` proposal and `context` use |
| POST | `/assistant/conversations/{id}/messages` | Send `{"text", "context", "model": {"port", "model"}}` (202). `context` is what the person sees |
| POST | `/assistant/conversations/{id}/decide` | Answer a proposal `{"proposal", "approve", "note"}` (202) |
| POST | `/assistant/conversations/{id}/stop` · `/rename` · `/settings` · `/delete` | Stop a turn; `{"title"}`; `{"budget", "thinking", "web"}` (`budget`: 8,192 to 1,048,576 tokens); delete |
| POST | `/assistant/conversations/{id}/documents` | Attach a document's text `{"name", "kind", "pages": ["page text", ...], "note"}` (201, up to 40 MB) |
| GET | `/assistant/model-context?model=` | The most tokens a downloaded model reads (`context`), or `null` |
