"""Local stdio MCP bridge to an explicitly started Dyno Research Lab."""
import argparse
import json
from typing import Literal
from urllib.parse import quote
from .sdk import Lab, ServingModel


def create_server(port=8980):
    from mcp.server.fastmcp import FastMCP
    from mcp.types import ToolAnnotations

    lab = Lab(f'http://127.0.0.1:{port}')
    server = FastMCP('Dyno Research Lab', instructions=(
        'Inspect local research jobs and submit isolated MLX experiments. Start Dyno Lab first. '
        'Experiments load another model copy and share GPU/memory with serving. '
        'The native UI resource gate does not apply to this bridge. Check resources and '
        'obtain the user\'s intent before submitting. Results are measurements, not safety certifications.'))
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)

    @server.tool(annotations=read)
    def lab_health() -> dict:
        """Check the local Lab service; does not start a service or load a model."""
        return lab.health()

    @server.tool(annotations=read)
    def lab_jobs() -> dict:
        """List recent experiment metadata, without full prompts or result arrays."""
        return {'jobs': lab.jobs()}

    @server.tool(annotations=read)
    def lab_job(job_id: str) -> dict:
        """Read a job's status, configuration, errors and completed measurements."""
        return lab.job(job_id)

    @server.tool(annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=True))
    def lab_submit(operation: Literal['inspect', 'compare', 'probe', 'sae'], model: str, settings: dict) -> dict:
        """Start one isolated experiment. Returns a job ID immediately; poll lab_job.

        model is a downloaded MLX directory or HF ID (may download weights).
        settings contains layers and operation-specific fields: prompt for inspect;
        prompt/intervention/strengths for compare; examples with text/split/label
        for probes; examples with text/split and features/steps for SAE.
        This consumes memory/GPU and can slow serving. No server is stopped.
        """
        if 'model' in settings or 'operation' in settings:
            raise ValueError('Pass model and operation as top-level arguments, not inside settings')
        return lab.submit(operation, model, **settings)

    @server.tool(annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False))
    def lab_cancel(job_id: str) -> dict:
        """Cancel only the chosen Lab worker. Does not stop inference servers."""
        return lab.cancel(job_id)

    @server.tool(annotations=read)
    def lab_artifacts(job_id: str) -> dict:
        """List artifact download URLs. Download large arrays through HTTP/SDK, not agent context."""
        job = lab.job(job_id)
        names = job.get('result', {}).get('artifacts', [])
        return {'artifacts': [dict(name=name, url=f'{lab.base_url}/lab/v1/jobs/{quote(job_id, safe="")}/artifacts/{quote(name, safe="")}') for name in names]}

    @server.tool(annotations=read)
    def serving_capabilities(port: int = 8971) -> dict:
        """Check whether a local inference endpoint can inspect its resident model."""
        return ServingModel(port).capabilities()

    @server.tool(annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False))
    def serving_inspect(prompt: str, layers: list[int], port: int = 8971, max_input_tokens: int = 128) -> dict:
        """Capture activation norms without another weight copy. Can delay serving.

        No interventions, training, chat template, raw tensor files or extra model
        load. The endpoint must have been started with the updated dyno serve.
        """
        return ServingModel(port).inspect(prompt, layers, max_input_tokens)

    @server.resource('dyno://lab/openapi')
    def openapi() -> str:
        """The local Research API's machine-readable schema."""
        return json.dumps(lab.schema())

    return server


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8980, help='Existing loopback Lab HTTP port (default: 8980)')
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error('port must be between 1 and 65535')
    try:
        server = create_server(args.port)
    except ImportError:
        parser.exit(1, "MCP support requires: pip install 'mlx-dyno[mcp]'\n")
    server.run(transport='stdio')
    return 0


if __name__ == '__main__':
    main()
