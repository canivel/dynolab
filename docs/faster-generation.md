# Faster generation

Dyno serves Qwen3.5, 3.6 and 3.8 models about twice as fast as plain MLX, with exactly the same output. Nothing to set up: start the model in **Models**, or run `dyno serve`, and it is on.

## Measured

Qwen3.8-27B 4-bit (`lmstudio-community/Qwen3.8-27B-MLX-4bit`) on an M5 Max with a 40-core GPU and 128 GB, nothing else running, one request at a time, thinking off. Decode speed in tokens per second, median of three runs.

With the model's recommended sampling (temperature 0.6, top-p 0.94, top-k 20):

| Workload | Dyno 0.6.10 | Dyno 0.6.11 | Speed-up |
|---|---|---|---|
| Chat | 22.9 | 33.3 | 1.45× |
| Code | 20.4 | 45.8 | 2.25× |
| Reasoning | 19.5 | 45.3 | 2.3× |
| Code edit | 19.8 | 46.8 | 2.35× |

Greedy (temperature 0), a 512-token code answer: 33.7 tok/s before, 66–75 tok/s now.

The gain depends on how predictable the text is. Code, step-by-step reasoning and edits that repeat their input gain the most; open-ended chat gains least.

The 0.6.10 column is slower than plain MLX can decode. Without a drafter, the server ran each request through mlx_lm's batching path, about a third slower than one request at a time. Since 0.6.13, a server started with `--decode-concurrency 1` (as the app starts models) decodes one request at a time without that path. Same Mac and model, 384-token answers, through the server, temperature 0 / 0.6:

| | Code | Chat |
|---|---|---|
| Plain, through the batching path (0.6.12) | 24.9 / 21.3 | 21.5 / 22.0 |
| Plain, one request at a time (0.6.13) | 33.0 / 29.3 | 29.9 / 29.0 |
| MTP head | 58.8 / 54.0 | 36.0 / 37.0 |
| DFlash2 | 67.8 / 66.5 | 43.4 / 43.3 |

Against plain decoding at full speed, the MTP head is about 1.8× on code and 1.25× on chat, and DFlash2 about 2.1× and 1.45×. Single runs; speeds drift a few percent with the GPU's temperature.

## How it works

Qwen3.5, 3.6 and 3.8 are trained with a small extra layer, a multi-token-prediction (MTP) head, that guesses the token after next from the model's last hidden state. MLX conversions drop it. Dyno puts it back and uses it for **speculative decoding**:

1. The head drafts the next few tokens. It is one layer instead of 64, so a draft costs about 1.5 ms.
2. The model checks all drafted tokens in a single pass. Reading the 15 GB of weights once dominates the cost of a pass on a Mac, so checking four tokens costs only about a third more than producing one.
3. Each drafted token is kept only if the model agrees with it. The first disagreement is replaced by the model's own token, and the rest is discarded, including the recurrent state of the model's linear-attention layers.

On code, about 3.5 tokens come out of each pass instead of one.

### Deeper drafts on M5 Macs

On Macs whose GPU has neural accelerators (M5 and later), Dyno checks drafts with its own matmul kernel, which runs on those accelerators and costs about the same for 16 tokens as for 5. On Qwen3.8-27B a 16-token check takes 44 ms instead of 153 ms, so the head can draft up to 7 tokens instead of 3, and on code and edits more tokens come out of each pass: 4.5–6.5 instead of about 3.3. Same setup as above, temperature 0.6, compared with the same server without the kernel:

| Workload | Without the kernel | With the kernel |
|---|---|---|
| Chat | 29.7–46.0 tok/s | 27.4–45.3 tok/s |
| Code | 40.1–56.6 tok/s | 49.1–77.1 tok/s |
| Reasoning | 38.8–54.3 tok/s | 55.4–81.8 tok/s |
| Code edit | 42.8–56.7 tok/s | 78.2–107.4 tok/s |

Ranges are two runs whose absolute speed differed with the GPU's temperature; within each run the kernel gained 1.2–1.9× on code, reasoning and edits, and made no difference to chat. The kernel is checked against MLX's own result before Dyno uses it. `DYNO_NAX=0` turns it off.

### A faster drafter: DFlash2

[DFlash2](https://inco.ai/blog/dflash2/) is a separate 1.6-billion-parameter drafter trained for Qwen3.8-27B. Instead of guessing one token at a time, it drafts a block of up to 7 tokens in a single pass, reading hidden states from five of the model's layers, and a small selector picks one coherent path through its top candidates. Its drafts are checked with the same exact rule, so the output is unchanged.

Dyno uses it when it's downloaded:

```sh
dyno pull z-lab/Qwen3.8-27B-DFlash2
```

The drafter is 3.2 GB to download and about 1.7 GB in memory, since Dyno loads it at 8 bits. With it on disk, `--speculative auto` drafts with DFlash2 instead of the MTP head; `--speculative mtp` keeps the head. Through the server, same setup, temperature 0.6, M5 Max on power:

| Workload | Plain | MTP head | DFlash2 |
|---|---|---|---|
| Chat | 22.2 tok/s | 35.4–37.4 tok/s | 32.7–36.9 tok/s |
| Code | 21.0 tok/s | 64.3–67.8 tok/s | 72.8–74.6 tok/s |
| Reasoning | 20.2 tok/s | 63.7–65.4 tok/s | 71.9–75.4 tok/s |
| Code edit | 20.2 tok/s | 78.1–80.0 tok/s | 81.0–89.5 tok/s |

Ranges are two sessions. DFlash2 is 10–15% faster on code and reasoning and about level on chat.

### The output doesn't change

At temperature 0 every kept token is the model's own top choice: the text is the model's greedy text. With sampling, drafts are accepted with the standard lossless rule (accept with probability min(1, p/q), otherwise resample from the difference), so each token has exactly the probability the model gives it, with your temperature, top-p and top-k. On a 256-token check, every token matched the model's own choice.

Requests with options the exact rule can't handle (logit biases, repetition penalties) are served without drafting.

## When it's on

`dyno serve --speculative auto`, the default, turns it on when:

- the model ships an MTP head: Qwen3.5, 3.6 and 3.8 dense models, including fine-tuned and abliterated versions (which use their base model's head, so fewer drafts are accepted, but output stays exact);
- the server decodes one request at a time, which is how the app starts large models. With `--decode-concurrency` above 1, Dyno batches requests instead.

`--speculative off` turns it off; `--speculative mtp` and `--speculative dflash` choose a drafter and say so when it's missing. Mixture-of-experts models (Qwen3.6-35B-A3B) aren't supported yet.

### On Macs before the M5

The speeds above are from an M5 Max, where checking several drafted tokens costs little more than generating one. On earlier chips it costs more: an M4 Max with 62% of drafts accepted decoded Qwen3.8-27B 4-bit at 13.6 tok/s with drafting, below its plain speed. Since 0.6.13 Dyno times a plain step next to every draft length it tries and decodes plain whenever that's faster, drafting one token every 8 steps to notice when the text becomes predictable enough (code, edits) for drafting to pay. On these Macs it should cost at most a few percent against plain decoding, and gain where drafts are accepted often enough.

## The draft head

The head is about 0.45 GB of extra memory. Dyno keeps one per base model in `~/.cache/dyno/mtp`. The first time, it takes it from the original full checkpoint if that's in your Hugging Face cache, or otherwise downloads just the head's weights from the original `Qwen/<model>` repository: about 0.85 GB, not the whole model. Set `HF_HUB_OFFLINE=1` to prevent the download, or pass `--mtp-head <folder>`.

## Checking it

The server log has one line per request:

```
MTP: 512 tokens in 147 rounds (3.48 per round), 365/437 drafts accepted
DFlash2: 383 tokens in 74 rounds (5.18 per round), 309/468 drafts accepted
```

`/stats` reports `speculative.mode` (`mtp`, `dflash` or null) and the drafted and accepted tokens, and `/metrics` has `mlx:draft_tokens_total` and `mlx:draft_tokens_accepted_total`.
