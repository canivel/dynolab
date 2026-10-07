# Local MCP server

Published guide: [dynolab.dev/guide.html](https://dynolab.dev/mcp.html)

Dyno includes a **stdio MCP bridge** for assistants and agent tools on your Mac.
It exposes the Research Lab through the [official MCP Python SDK](https://py.sdk.modelcontextprotocol.io/v1/).
It is not an inference server, and it does not listen on a network port.

## Setup

Start **Lab → Analyze** in Dyno, or run `dyno lab --port 8980`.
The bridge connects to that existing loopback service. Starting MCP alone does
not start a Lab worker, download a model, or submit an experiment.

From a checkout of this repository:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[serve,mcp]'
dyno mcp --port 8980
```

A stdio server waits for an MCP client; it has no interactive terminal prompt.
Configure your client's MCP server settings using either the installed `dyno`
executable (use its absolute path if your client does not inherit PATH), or the
launcher bundled in an updated Dyno app:

```json
{
  "mcpServers": {
    "dyno": {
      "command": "/Applications/Dyno.app/Contents/MacOS/dyno-cli",
      "args": ["mcp", "--port", "8980"]
    }
  }
}
```

The launcher resolves its own runtime after relocation. Adjust the app path if
Dyno is installed elsewhere. The `mcpServers` envelope is a common client format;
use your client's equivalent command and argument fields when its format differs.
The current Mac DMG contains this launcher. Upgrade older installations from
[GitHub Releases](https://github.com/canivel/dynolab/releases/latest).

## Tools

| Tool | Purpose | Effect |
|---|---|---|
| `serving_capabilities` | Discover resident capture support on an inference port | Read only |
| `serving_inspect` | Capture norms using loaded weights | Brief extra GPU/workspace use, no weight copy |
| `lab_health` | Check service availability | Read only |
| `lab_jobs` | List recent experiment metadata | Read only |
| `lab_job` | Read configuration, status, results or errors | Read only |
| `lab_submit` | Submit `inspect`, `compare`, `probe` or `sae` | Loads a separate model and runs an experiment |
| `lab_cancel` | Cancel the selected experiment worker | Stops that worker only |
| `lab_artifacts` | List HTTP download links for saved artifacts | Read only |

### Agent sandbox test tools

| Tool | Purpose | Effect |
|---|---|---|
| `environments`, `environment` | List environment templates; read one | Read only |
| `environment_from_compose` | Convert a Docker Compose file into an environment; `save=true` saves a valid one | Saving adds an environment |
| `save_environment` | Save an environment template | Adds or replaces one of yours |
| `export_test_package`, `preview_test_package`, `import_test_package` | Share a test as a package; read one from a link and see what it would create and run; import it | Importing saves an environment and a prompt |
| `export_run_result`, `export_eval_result` | Package one test's result or an Evals table to share on Dyno Research | Read only |
| `agent_tests`, `agent_test` | List tests; read one test's transcript, Observer entries and verdict (pass `after`/`observed` to follow a running test) | Read only |
| `plan_agent_test` | Check a setup: how each rule will be watched and what to fix | Read only |
| `start_agent_test` | Start a test with a `spec` (see the [HTTP API](http-api.md#agent-sandbox-tests)) | Runs a sandbox and a local model; get the user's go-ahead |
| `message_agent_test` | Write in a running test's chat | Agents read it; the test becomes interactive |
| `end_agent_test` | End a test; a waiting room closes and is sealed | Ends the test |
| `export_agent_test` | Write the full log (`md`) or raw files (`zip`) on this Mac | Writes a file |
| `agent_evals`, `agent_eval_cell`, `compare_agent_configs` | Safe rates with 95% ranges, one cell's metrics, a paired comparison | Read only |
| `eval_batches`, `start_eval_batch`, `cancel_eval_batch` | List, start (one scenario × N runs per model) or stop batches | Starting runs many tests; get the user's go-ahead |
| `agent_prompts`, `save_agent_prompt` | Read prompts and versions; save a prompt or a new version | Saving adds a version |
| `observer_alerts`, `save_observer_alert` | Read or define alerts that run in new tests | Saving changes future tests |

Ask your assistant, for example: “List my agent tests, then summarize the Observer's verdict and the rule events of the newest one.” The Observer is hidden from the agents: an assistant shouldn't paste it into a running test's chat unless you ask.

### Tool arguments

| Tool | Arguments |
|---|---|
| `lab_health`, `lab_jobs` | None |
| `lab_job`, `lab_cancel`, `lab_artifacts` | `job_id`: returned job identifier |
| `lab_submit` | `operation`, `model`, `settings` object; keep model/operation out of settings |
| `serving_capabilities` | `port` (default 8971) |
| `serving_inspect` | Required `prompt`, `layers`; optional `port` (8971), `max_input_tokens` (128) |

For a first resident capture, ask your connected assistant: “Check the Dyno serving capabilities on port 8971, then capture layers 4 and 8 for the raw prompt ‘The capital of France is’ using the loaded model.” Choose layers that exist in your model. This returns measurements directly; there is no job ID to poll.

The resource `dyno://lab/openapi` returns the service's OpenAPI schema.
Large arrays stay in artifact files; use the SDK or HTTP URLs to download them.

Example `lab_submit` arguments:

```json
{
  "operation": "inspect",
  "model": "mlx-community/Qwen1.5-0.5B-Chat-4bit",
  "settings": {
    "prompt": "The capital of France is",
    "layers": [4, 8],
    "max_input_tokens": 256
  }
}
```

Submission returns a job ID immediately. Call `lab_job` to poll that ID, then
`lab_artifacts` for files. Only one experiment can run at a time. A model ID may
download weights; a local model path uses your existing download.

## Resources and privacy

The MCP bridge and Python SDK use the same job API. The native UI's memory/GPU
admission check does **not** apply to these clients. Check headroom and serving
activity before submitting, especially for a large model. Separate processes
still compete for unified memory and GPU bandwidth. Cancellation never stops a
serving model; the bridge cannot reconfigure or unload inference servers.

Job inputs and results are stored locally, but a connected assistant can read
them and may send tool results to its model provider. Choose which jobs and
prompts you expose accordingly. There is no remote MCP transport, shell tool,
arbitrary file reader, or automatic connection to an assistant in this release.

## Troubleshooting

- **Connection refused:** start Lab and match the configured port.
- **MCP dependency missing:** install `.[mcp]` from the checkout, or use the updated app launcher.
- **A job is already running:** poll its status or cancel that Lab job.
- **Older Lab service:** quit the instance that owns the old Lab process and reopen the updated build.
- **Model error:** inspect the job error and verify its architecture, layers and input limits. Hybrid Qwen layers are covered by regression tests; support is not universal across every MLX model.

`serving_inspect` connects directly to an updated Dyno inference endpoint and does not require the Lab job service. Use it for read-only norms; use `lab_submit` for isolated jobs.

## Local development preview

Controlled comparisons now have a local protocol runner, saved attempts and human labels. See [Controlled studies](controlled-studies.md) for the UI, SDK, API, MCP tools and current limits.


### Context-masked response review (local preview)

Saved controlled-study responses can now be reviewed in a shuffled queue with condition and model labels hidden, append-only judgments, self-reported prior exposure, and an explicit permanent reveal. See [the workflow and API examples](controlled-studies.md#review-with-conditions-hidden-local-preview). No running model is required. This is a review aid, not authenticated or guaranteed blind review.


## Response monitor evaluations (local preview)

Compare model scores with frozen reference labels, review separate development/test metrics, and inspect disagreements. See the [monitor evaluation walkthrough](monitor-evaluations.md) for UI, SDK, HTTP and MCP instructions and limits.

Grouped probes now have a [validation workflow](probe-validation.md) with separate training, validation and test groups, and baseline controls (local preview).

## Additional local research workflows

- [Regression reports](regression-reports.md): Compare paired labeled outcomes and inspect exclusions.
- [Artifact compatibility](compatibility-checks.md): Check a saved artifact contract before considering reuse.
- [Checkpoint comparisons](checkpoint-comparisons.md): Compare saved runs with the same protocol across checkpoints.
- [Simulated agent tasks](simulated-agent-tasks.md): Inspect bounded actions and verification claims.
- [Community reproductions](community-reproductions.md): Connect a new attempt to the exact shared study version.
- [Monitor threshold selection](monitor-evaluations.md): select on development predictions before evaluating held-out data.

These features are local previews. Guides separate measured evidence, user-supplied metadata and unsupported operations.

## From a saved study to deeper analysis

The native app can prepare an analysis from a notebook study or a controlled comparison. This is a dataset draft, not an automatic scientific label. Review the copied text, labels, scenario groups and train/validation/test assignments before submitting a probe. Notebook prompts need explicit labels; condition labels in a controlled comparison identify the prompt condition, not whether the response was sycophantic.

Use the same reviewed configuration through the job submission API, SDK or MCP tool. Keep source study and entry identifiers with your exported evidence. Saving an experiment does not publish it to the community. See the [worked probe tutorial](probe-tutorial.md) and [grouped validation guide](probe-validation.md).
