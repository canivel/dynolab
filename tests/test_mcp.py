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
from dyno.lab.monitors import Monitors
from dyno.lab.regressions import ResearchReports
from dyno.lab.agent_tasks import AgentTasks
from test_monitors import config, score
from dyno.lab.studies import Studies
from test_controlled_studies import protocol, response


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
            server.studies = Studies(Path(root) / 'controlled-studies', response)
            server.reports = ResearchReports(Path(root)/'reports',server.studies)
            server.agent_tasks = AgentTasks(Path(root)/'tasks',response)
            server.monitors = Monitors(Path(root)/'monitors',server.studies,lambda *_:score())
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
                        self.assertEqual({t.name for t in tools}, {'lab_health','lab_jobs','lab_job','lab_submit','lab_cancel','lab_artifacts','serving_capabilities','serving_inspect','check_artifact_compatibility','select_monitor_threshold','prepare_simulated_task','run_simulated_task','cancel_simulated_task','simulated_task','compare_checkpoints','create_regression_report','research_reports','research_report', 'controlled_studies','controlled_study','prepare_controlled_study','run_controlled_study','cancel_controlled_study','prepare_study_review','study_review','label_study_review','reveal_study_review','study_reproduction_report','monitor_evaluations','prepare_monitor_evaluation','run_monitor_evaluation','cancel_monitor_evaluation','monitor_evaluation','monitor_evaluation_report'})
                        def content(result):
                            self.assertFalse(result.isError)
                            return json.loads(result.content[0].text)
                        self.assertEqual(content(await session.call_tool('lab_health'))['status'], 'ok')
                        self.assertEqual(content(await session.call_tool('monitor_evaluations'))['evaluations'], [])
                        prepared = content(await session.call_tool('prepare_controlled_study', {'protocol': protocol()}))
                        self.assertEqual(prepared['status'], 'prepared')
                        saved = content(await session.call_tool('controlled_study', {'study_id': prepared['id']}))
                        self.assertEqual(saved['runs'], [])
                        self.assertIsNone(server.studies.active)
                        server.studies.run(prepared['id'], 8971, 'fixture-model')
                        import asyncio
                        for _ in range(100):
                            if server.studies.active is None: break
                            await asyncio.sleep(.01)
                        review = content(await session.call_tool('prepare_study_review', {'study_id':prepared['id'], 'reviewer':'Agent test', 'prior_exposure':True}))
                        reread = content(await session.call_tool('study_review', {'study_id':prepared['id'], 'review_id':review['id']}))
                        self.assertEqual(review, reread)
                        labeled = content(await session.call_tool('label_study_review', {'study_id':prepared['id'], 'review_id':review['id'], 'item_id':review['items'][0]['id'], 'value':'uncertain'}))
                        self.assertEqual(labeled['reviewed'], 1)
                        revealed = content(await session.call_tool('reveal_study_review', {'study_id':prepared['id'], 'review_id':review['id']}))
                        self.assertIn('context', revealed['items'][0])
                        source = server.studies.read(prepared['id'])
                        for run in source['runs']:
                            server.studies.label(prepared['id'],run['id'],'pass','Agent test')
                        m=content(await session.call_tool('prepare_monitor_evaluation',{'study_id':prepared['id'],'config':config()}))
                        self.assertEqual(m['runs'],[])
                        content(await session.call_tool('run_monitor_evaluation',{'evaluation_id':m['id']}))
                        for _ in range(100):
                            if server.monitors.active is None: break
                            await asyncio.sleep(.01)
                        mr=content(await session.call_tool('monitor_evaluation_report',{'evaluation_id':m['id']}))
                        self.assertEqual(mr['rows'][0]['metrics']['fp'],2)

                        report=content(await session.call_tool('create_regression_report',{'config':dict(title='MCP regression',baseline='neutral',comparison='pressure',sources=[dict(metric='honesty',study_id=prepared['id'])])}))
                        self.assertEqual(content(await session.call_tool('research_report',{'report_id':report['id']}))['id'],report['id'])
                        compatibility=content(await session.call_tool('check_artifact_compatibility',{'source_job_id':identifier,'target_job_id':identifier}))
                        self.assertFalse(compatibility['compatibility']['allowed'])
                        task=content(await session.call_tool('prepare_simulated_task',{'config':dict(title='MCP task',port=8971,model='fixture',condition='neutral')}))
                        self.assertEqual(content(await session.call_tool('simulated_task',{'task_id':task['id']}))['status'],'prepared')
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
