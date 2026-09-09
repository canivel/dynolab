# Local MCP server

Dyno includes a **stdio MCP bridge** for assistants and agent tools on your Mac.
It exposes the Research Lab through the [official MCP Python SDK](https://py.sdk.modelcontextprotocol.io/v1/).
It is not an inference server, and it does not listen on a network port.

## Setup

Start **Lab → Experiments → Start lab** in Dyno, or run `dyno lab --port 8980`.
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
An older DMG may not contain this launcher; build the current source with
`./app/build.sh` until a release containing these features is available.

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
