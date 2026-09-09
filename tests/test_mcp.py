import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    HAS_MCP = True
except ImportError:
    HAS_MCP = False
from dyno.lab.server import Handler, Jobs, validate


@unittest.skipUnless(HAS_MCP, 'Install the mcp extra')
class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_client_to_http_roundtrip(self):
        with tempfile.TemporaryDirectory() as root:
            jobs = Jobs(root)
            identifier = 'c' * 32
            folder = Path(root) / identifier
            folder.mkdir()
            data = dict(id=identifier, created=0, status='completed', result={'artifacts':['activations.npz']})
            jobs.write(folder / 'job.json', data)
            submissions = []
            def submit(config):
                submissions.append(validate(config))
                return dict(id=identifier, status='queued')
            jobs.submit = submit  # No GPU work in the transport test.
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server.jobs = jobs
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                launcher = os.environ.get('DYNO_MCP_TEST_COMMAND')
                params = StdioServerParameters(command=launcher or sys.executable,
                    args=([] if launcher else ['-m','dyno']) + ['mcp','--port',str(server.server_port)],
                    env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]/'src') + os.pathsep + os.environ.get('PYTHONPATH', '')))
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        tools = (await session.list_tools()).tools
                        self.assertEqual({t.name for t in tools}, {'lab_health','lab_jobs','lab_job','lab_submit','lab_cancel','lab_artifacts','serving_capabilities','serving_inspect'})
                        def content(result):
                            self.assertFalse(result.isError)
                            return json.loads(result.content[0].text)
                        self.assertEqual(content(await session.call_tool('lab_health'))['status'], 'ok')
                        self.assertEqual(len(content(await session.call_tool('lab_jobs'))['jobs']), 1)
                        self.assertEqual(content(await session.call_tool('lab_job', {'job_id':identifier}))['id'], identifier)
                        self.assertIn('activations.npz', content(await session.call_tool('lab_artifacts', {'job_id':identifier}))['artifacts'][0]['url'])
                        result = content(await session.call_tool('lab_submit', {'operation':'inspect','model':'test-model','settings':{'prompt':'hello','layers':[0]}}))
                        self.assertEqual(result['status'], 'queued')
                        self.assertEqual(submissions[0]['prompt'], 'hello')
                        content(await session.call_tool('lab_cancel', {'job_id':identifier}))
                        schema = await session.read_resource('dyno://lab/openapi')
                        self.assertEqual(json.loads(schema.contents[0].text)['openapi'], '3.0.3')
            finally:
                server.shutdown(); server.server_close(); thread.join(); jobs._directory_lock.close()
