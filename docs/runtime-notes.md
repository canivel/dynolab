# Runtime and telemetry notes

Technical background for Dyno Lab’s local inference and hardware telemetry. For installation and research workflows, start with the [app handbook](app-guide.md).

## Serving from the command line

```sh
dyno serve --model mlx-community/Qwen3-8B-4bit --port 8971
```

```
Dyno CLI  ·  serving with live metrics
  OpenAI API   http://127.0.0.1:8971/v1
  Metrics      http://127.0.0.1:8971/metrics   (Prometheus)
  Stats        http://127.0.0.1:8971/stats     (JSON)
```

### Not a fork

`dyno serve` imports `mlx_lm.server`, swaps two classes for instrumented
subclasses, and hands control back. Every existing flag keeps working, and so do
mlx_lm's batching, prompt caching and speculative decoding. The additions are
timing hooks inside the token stream and two endpoints.

Hooking the token stream rather than the HTTP layer means streaming and
non-streaming requests are measured identically.

### Tool calling for any model

Some models ship a chat template that knows only system, user and assistant turns; abliterated and merged models
often do. Through such a template the tool list never reaches the model, tool results are dropped, and the model's
tool call comes back as plain text, so the assistant or an agent stops after its first step. When `dyno serve` loads
a model whose template doesn't handle tools, it fixes that:

1. It uses the template of another downloaded model of the same family (the same `model_type`, the same
   architecture preferred), when every special token that template uses is in this model's vocabulary.
2. Otherwise it uses a built-in format that works through any template. The tools are described in the system
   message, earlier calls and their results are written into the turns as text, and `<tool_call>` blocks in the reply
   are returned as tool calls (JSON, or the `<function=…>` form Qwen models use).

A model whose own template handles tools is left alone. `/stats` reports which applies under `model.tool_calls`:
`own`, `borrowed:<model>`, `built-in`, or `none`. A model that ships no chat template at all also borrows one from its family when it can; with none to borrow it stays on mlx_lm's plain prompt format (`none`).

### Faster generation with the model's own draft head

Qwen3.5, 3.6 and 3.8 models are trained with a small extra layer, a multi-token-prediction (MTP) head, that guesses the token after next. MLX conversions usually drop it. `dyno serve` puts it back and uses it for speculative decoding: the head drafts a few tokens, the model checks them all in one pass, and only the tokens the model would have produced are kept. Sampled tokens are accepted with the standard lossless rule, so the output has exactly the model's own distribution at any temperature, top-p and top-k; at temperature 0 it is the model's own greedy text.

Qwen3.8-27B 4-bit on an M5 Max (40-core GPU), one request at a time, temperature 0.6, top-p 0.94, top-k 20, median of three runs:

| Workload | Without | With the MTP head |
|---|---|---|
| Chat | 22.9 tok/s | 33.3 tok/s (1.45×) |
| Code | 20.4 tok/s | 45.8 tok/s (2.25×) |
| Reasoning | 19.5 tok/s | 45.3 tok/s (2.3×) |
| Code edit | 19.8 tok/s | 46.8 tok/s (2.35×) |

It is on by default (`--speculative auto`) when the model ships a head and the server decodes one request at a time, which is how the app starts large models. With `--decode-concurrency` above 1, batching is used instead. `--speculative off` turns it off; `--speculative mtp` requires it.

The head is kept once per base model in `~/.cache/dyno/mtp`. Dyno takes it from a full original checkpoint already in your Hugging Face cache, or else downloads only the head's tensors from the original `Qwen/<model>` repository (about 0.85 GB for Qwen3.8-27B; set `HF_HUB_OFFLINE=1` to prevent it). `--mtp-head` points at a folder of your own. Fine-tuned and abliterated models use their base model's head: output is still exact, only fewer drafts are accepted. Mixture-of-experts heads (Qwen3.6-35B-A3B) are not supported yet.

`/stats` reports `speculative.mode` and the drafted and accepted token counts; Prometheus has `mlx:draft_tokens_total` and `mlx:draft_tokens_accepted_total`.

If a model can't load (for example a download that stopped part-way and is missing a weight file), `dyno serve` exits with one line saying why instead of answering requests it can never complete. The app marks such a model *incomplete download* and won't start it.

## The metrics

| Metric | Meaning |
|---|---|
| `mlx:decode_tokens_per_second` | In-flight throughput; falls back to recent history when idle |
| `mlx:live_decode_tokens_per_second` | Requests generating right now, summed |
| `mlx:last_time_to_first_token_seconds` | Prompt processing plus queue wait |
| `mlx:last_prompt_tokens_per_second` | Prefill throughput |
| `mlx:cached_prompt_tokens_total` | Prompt tokens the cache served |
| `mlx:tokens_generated_total`, `mlx:prompt_tokens_total` | Cumulative counters |
| `mlx:requests_active`, `mlx:requests_total`, `mlx:requests_failed_total` | Request state |
| `mlx:memory_active_bytes`, `_peak_bytes`, `_cache_bytes` | MLX allocator |
| `mlx:model_load_seconds`, `mlx:uptime_seconds` | Server state |

The decode rate deliberately excludes prompt processing and queue time: it is
tokens produced divided by the time spent producing them, which is the number
that answers "how fast does this model generate". Verified against wall-clock
timing — a request that took 5.46 s end to end with 0.36 s to first token
reported 31.2 tok/s, exactly `159 ÷ 5.10`.

`/stats` returns the same figures as JSON, plus the last ten requests
individually (queue wait, TTFT, prefill rate, decode rate, cache hits, finish
reason).

## Other runtimes

The app is not MLX-only. It also reads:

- **llama.cpp** — `/props` for the model, `/metrics` for measured throughput
  (start it with `--metrics`)
- **vLLM** — `/metrics`
- **Ollama** — `/api/ps` for resident models and their VRAM
- **LM Studio** and anything OpenAI-compatible — `/v1/models`

For a runtime that reports no throughput, the app estimates it from memory
bandwidth and always marks it `≈ est.`, showing `—` rather than a number
whenever more than one model is loaded and bandwidth cannot be attributed.

## Measuring, honestly

```sh
dyno bench --model A --model B --repeat 3 --csv results.csv
```

Not another tokens-per-second number. Numbers like that are posted constantly
and are almost never comparable: different prompts, a warm or cold machine,
something else on the GPU. `dyno bench` runs models **one at a time** so each
sees the same memory situation, records the conditions next to the result, and
says when they make a comparison unsafe:

```
model                        tok/s  spread   TTFT   weights  agree
Qwen1.5-0.5B-Chat             65.6     54%  0.18s   1.15 GB    ref
Qwen1.5-0.5B-Chat-4bit        90.5     17%  0.25s   0.24 GB     0%

Conditions that make these numbers unsafe to compare:
  Qwen1.5-0.5B-Chat: mlx_lm.server held 43.2 GB of GPU memory
```

Two things there most harnesses do not report. **Spread** — how much the trials
disagreed, so a 54% spread tells you the median is not yet a measurement. And
**agreement** — how often a model gave byte-identical output to the reference at
the same seed. It is a crude quality proxy and says so: identical output means
the quantisation changed nothing on that prompt, not that either answer is good.

## Looking inside a generation

```sh
dyno inspect "why do B-trees suit range queries" --port 8971 --port 8973
```

Every token carries the probability the model gave it and the alternatives it
weighed. That answers where a model hesitated — and, with two builds of one
model at the same seed, exactly what a quantisation cost:

```
Qwen1.5-0.5B-Chat vs Qwen1.5-0.5B-Chat-4bit
  diverged at token 6 of 90 (73 tokens differ)
    6  'efficient' (20%)  →  'optimized' (30%)   reference considered it
   11  'they' (97%)       →  'as' (32%)          reference never considered it
```

That last column is the useful one. A divergence the reference also ranked is a
near-tie; one it never ranked at all is the cheaper build going somewhere the
original would not have.

## Machine metrics

No `sudo`, ever. Most Apple Silicon monitors shell out to `powermetrics`, which
needs root; this reads the same counters one level down through `IOReport`,
IOKit and Metal, all readable by a normal user.

- **GPU** busy percentage from P-state residency, and the clock averaged over
  busy time only — a GPU pinned at 100% on a low clock is power- or
  thermally-limited, not working hard.
- **GPU memory** against Metal's `recommendedMaxWorkingSetSize`, the real
  ceiling for weights plus KV cache.
- **Memory bandwidth**, estimated from the controller's histogram — quantised to
  the bucket width, and labelled as an estimate.
- **Power** for the GPU, CPU, DRAM and Neural Engine rails separately, the SoC
  total, and wall draw against the adapter's rating.

`Device Utilization %` from the IOKit accelerator node, which several other
tools report as GPU usage, is unreliable on recent macOS — it reads near 100% on
an idle machine. This ignores it in favour of P-state residency.

```sh
dyno serve --model <path>      # run a model with metrics
dyno route                     # one endpoint in front of them all
dyno run "explain B-trees"     # one prompt, one answer, with the numbers
dyno ps / dyno stop            # what is running, and stopping it
dyno pull <repo-id>            # download a model from the hub
dyno bench --model A --model B # measure, with the conditions recorded
dyno inspect "…" --port 8971   # token probabilities and quantisation diffs
dyno harness install aider     # point a coding tool at your models
dyno top                       # live dashboard
dyno top --once                # one snapshot
dyno top --json                # newline-delimited JSON
dyno top --csv run.csv -i 0.5  # log a benchmark run
```

## Why is the server Python if the app is native?

The app *is* native — all of it. GPU residency, power rails, memory, bandwidth,
process scanning, model discovery, server supervision and the entire UI are
Swift, with no Python anywhere near them. And you never install Python yourself:
it lives inside the app bundle, the same way Ollama ships its own runtime.

The inference server is Python because that is where MLX's model support lives.
`mlx_lm` ships 119 model files — Llama 4, DeepSeek V3.2, Gemma 4, GLM-4, Qwen,
GPT-OSS, Kimi and the rest — with Hugging Face tokenizers, chat templates,
quantisation, batching, prompt caching and speculative decoding, and it picks up
new architectures within days of release. `mlx-swift` can run models natively in
Swift, but reimplementing that surface would mean tracking upstream by hand
forever, and the result would support a fraction of the models.

So the server runs as a *child process*, never embedded: a model load that runs
out of memory cannot take the monitor down with it.

## Layout

```
src/dyno/
  cli.py           the `dyno` entry point
  serve/           the instrumented MLX server
  monitor/         hardware telemetry and the terminal dashboard
app/
  Sources/DynoKit/ IOReport, IOKit, libproc, Metal, model + server discovery
  Sources/Dyno/    SwiftUI menu bar app
  Sources/probe/   command-line harness for the metrics layer
  build.sh         compiles and assembles Dyno.app
docs/              app, SDK, API and maintenance documentation
```

`app/.build/release/probe` prints the Swift layer's raw readings, which is the
quickest way to check what the app is seeing.

## Compatibility

`dyno serve` needs `mlx-lm >= 0.28` and hooks three internals of
`mlx_lm.server` (`ResponseGenerator`, `_run_http_server`, `ModelProvider.load`).
Those are checked at start-up: if a future mlx_lm reshapes them it fails loudly
rather than serving without metrics.

