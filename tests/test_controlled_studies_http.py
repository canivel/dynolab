"""Exercise the public SDK against the real HTTP handler, without model weights."""
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer
from dyno.lab.server import Handler
from dyno.lab.monitors import Monitors
from dyno.lab.regressions import ResearchReports
from dyno.lab.agent_tasks import AgentTasks
from test_monitors import config, score
from dyno.lab.studies import Studies
from dyno.sdk import Lab, DynoError
from test_controlled_studies import protocol, response


class StudyHTTPTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.studies = Studies(self.temp.name, response)
        self.server.agent_tasks = AgentTasks(self.temp.name+'/tasks',lambda *_:response(8971,dict(model='fixture')))
        self.server.reports = ResearchReports(self.temp.name+'/reports',self.server.studies)
        self.server.monitors = Monitors(self.temp.name+'/monitors', self.server.studies, lambda *_: score())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)
        self.lab = Lab(self.base)

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def test_sdk_roundtrip_and_review(self):
        s = self.lab.create_study(protocol()); sid = s['id']
        self.lab.run_study(sid, 8971, 'fixture-model')
        deadline = time.monotonic() + 2
        while self.server.studies.active and time.monotonic() < deadline: time.sleep(.01)
        s = self.lab.study(sid)
        self.assertEqual(s['status'], 'finished')
        self.lab.label_run(sid, s['runs'][0]['id'], 'pass', 'Reviewer')
        self.assertEqual(sum(r['passed'] for r in self.lab.study_summary(sid)['rows']), 1)
        review = self.lab.prepare_review(sid, 'Independent', False)
        self.assertEqual(self.lab.review(sid, review['id']), review)
        labeled = self.lab.review_label(sid, review['id'], review['items'][0]['id'], 'pass', 'Reviewed')
        self.assertEqual(labeled['reviewed'], 1)
        self.assertNotIn('context', labeled['items'][0])
        revealed = self.lab.reveal_review(sid, review['id'])
        self.assertIn('context', revealed['items'][0])
        bundle = self.lab.export_study(sid)
        imported = self.lab.import_study(bundle)
        with self.assertRaises(DynoError): self.lab.run_study(imported['id'], 8971, 'fixture-model')
        copy = self.lab.reproduce_study(imported['id'])
        self.assertEqual(copy['protocol']['parent_hash'], bundle['sha256'])
        self.assertEqual(len(self.lab.studies()), 3)
        self.assertEqual(self.lab.reproduction_report(copy['id'])['missing'], 2)

    def test_monitor_sdk_roundtrip(self):
        s = self.lab.create_study(protocol()); sid = s['id']
        self.lab.run_study(sid, 8971, 'fixture-model')
        deadline = time.monotonic()+2
        while self.server.studies.active and time.monotonic()<deadline: time.sleep(.01)
        for r in self.lab.study(sid)['runs']: self.lab.label_run(sid,r['id'],'pass','HTTP fixture')
        m=self.lab.prepare_monitor(sid,config()); self.assertEqual(m['runs'],[])
        self.assertEqual(self.lab.monitors()[0]['id'],m['id'])
        self.lab.run_monitor(m['id'])
        deadline=time.monotonic()+2
        while self.server.monitors.active and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(self.lab.monitor_report(m['id'])['rows'][0]['metrics']['fp'],2)
        self.assertEqual(self.lab.export_monitor(m['id'])['schema'],'dyno.monitor-evaluation/1')
        self.assertEqual(self.lab.monitor(m['id'])['status'],'finished')
        report=self.lab.regression_report(dict(title='HTTP report',baseline='neutral',comparison='pressure',sources=[dict(metric='honesty',study_id=sid)]))
        self.assertEqual(self.lab.research_report(report['id'])['results'][0]['rows'][0]['scored_pairs'],1)
        with self.assertRaises(DynoError):self.lab._request('/monitors/'+m['id']+'/run',{'port':9999})

    def test_agent_and_checkpoint_sdk_transport(self):
        task=self.lab.prepare_agent_task(dict(title='HTTP task',port=8971,model='fixture',condition='neutral'))
        self.assertEqual(self.lab.agent_task(task['id'])['status'],'prepared')
        self.assertEqual(self.lab.agent_tasks()[0]['id'],task['id'])
        with self.assertRaises(DynoError):self.lab._request('/agent-tasks/'+task['id']+'/run',{'extra':True})
        ids=[self.lab.create_study(protocol())['id'] for _ in range(2)]
        report=self.lab.checkpoint_report(dict(title='Empty comparison',sources=[dict(label=str(i),study_id=id,revision='unknown',training_data='unknown',adapter='none') for i,id in enumerate(ids)]))
        self.assertEqual(self.lab.research_report(report['id'])['results'][0]['rows'][0]['scored_pairs'],0)
        self.assertEqual(len(self.lab.research_reports()),1)

    def test_foreign_origin_cannot_create(self):
        req = urllib.request.Request(self.base+'/lab/v1/studies', data=b'{}', headers={'Origin':'https://untrusted.example', 'Content-Type':'application/json'})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(req)
        self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.lab.studies(), [])

    def test_non_object_and_bad_monitor_records(self):
        with self.assertRaises(DynoError): self.lab._request('/studies', [])
        result = self.lab.monitor_metrics([None, {'reference': False, 'score': .1}], .5)
        self.assertEqual(result['excluded'], 1)
        self.assertEqual(result['tn'], 1)
