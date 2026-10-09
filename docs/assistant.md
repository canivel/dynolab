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
- **What it asks first:** starting a test, running an Evals batch, saving or running an Inspect eval, and saving an agent prompt. Each shows a card with what will happen. **Approve** runs it, **Decline** doesn't, and you can add a note either way. Writing a message instead of choosing counts as not approving. Only your click runs anything.
- **Conversations** are in the title menu: new, open, rename, delete. **Plain chat with a model** opens the old full-window chat.

## The context window

A model can only read so much at once. A long conversation is kept small for the model without losing anything on disk:

- **On disk:** each conversation is an append-only log, never shortened.
- **Sent to the model on each turn:** the instructions, the task list and your current screen, always. Then the recent turns.
- **Left out:** the model's own thinking is never sent back. Tool results older than the last two messages become a one-line note, and the model can look again if it needs to.
- **Summarized:** when a conversation nears its budget (32K tokens by default, adjustable from 16K to 128K in the panel's settings), the model writes a running summary of the older turns. The summary is saved in the log, and the last four turns always stay in full. A grey line in the chat marks where turns were summarized; click it to read the summary.
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
| POST | `/assistant/conversations/{id}/stop` · `/rename` · `/settings` · `/delete` | Stop a turn; `{"title"}`; `{"budget", "thinking"}`; delete |
