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

## How it works

Qwen3.5, 3.6 and 3.8 are trained with a small extra layer, a multi-token-prediction (MTP) head, that guesses the token after next from the model's last hidden state. MLX conversions drop it. Dyno puts it back and uses it for **speculative decoding**:

1. The head drafts the next few tokens. It is one layer instead of 64, so a draft costs about 1.5 ms.
2. The model checks all drafted tokens in a single pass. Reading the 15 GB of weights once dominates the cost of a pass on a Mac, so checking four tokens costs only about a third more than producing one.
3. Each drafted token is kept only if the model agrees with it. The first disagreement is replaced by the model's own token, and the rest is discarded, including the recurrent state of the model's linear-attention layers.

On code, about 3.5 tokens come out of each pass instead of one.

### The output doesn't change

At temperature 0 every kept token is the model's own top choice: the text is the model's greedy text. With sampling, drafts are accepted with the standard lossless rule (accept with probability min(1, p/q), otherwise resample from the difference), so each token has exactly the probability the model gives it, with your temperature, top-p and top-k. On a 256-token check, every token matched the model's own choice.

Requests with options the exact rule can't handle (logit biases, repetition penalties) are served without drafting.

## When it's on

`dyno serve --speculative auto`, the default, turns it on when:

- the model ships an MTP head: Qwen3.5, 3.6 and 3.8 dense models, including fine-tuned and abliterated versions (which use their base model's head, so fewer drafts are accepted, but output stays exact);
- the server decodes one request at a time, which is how the app starts large models. With `--decode-concurrency` above 1, Dyno batches requests instead.

`--speculative off` turns it off, and `--speculative mtp` stops with an error if no head is available. Mixture-of-experts models (Qwen3.6-35B-A3B) aren't supported yet.

## The draft head

The head is about 0.45 GB of extra memory. Dyno keeps one per base model in `~/.cache/dyno/mtp`. The first time, it takes it from the original full checkpoint if that's in your Hugging Face cache, or otherwise downloads just the head's weights from the original `Qwen/<model>` repository: about 0.85 GB, not the whole model. Set `HF_HUB_OFFLINE=1` to prevent the download, or pass `--mtp-head <folder>`.

## Checking it

The server log has one line per request:

```
MTP: 512 tokens in 147 rounds (3.48 per round), 365/437 drafts accepted
```

`/stats` reports `speculative.mode` (`mtp` or null) and the drafted and accepted tokens, and `/metrics` has `mlx:draft_tokens_total` and `mlx:draft_tokens_accepted_total`.
