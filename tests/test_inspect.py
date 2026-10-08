import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from dyno.lab.inspect_runs import available, parse_import
from dyno.lab.sandbox import SandboxRuns


class FakeChat:
    """An OpenAI-compatible local server: answers the questions, and grades like a judge when asked to."""
    def __init__(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _send(self, body):
                data = json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self): self._send({'object': 'list', 'data': [{'id': 'default_model', 'object': 'model'}]})
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                text = json.dumps(req['messages'])
                if 'GRADE' in text: answer = 'The answer matches. GRADE: C'
                elif 'France' in text: answer = 'Paris'
                elif '2+2' in text: answer = '4'
                else: answer = 'I am not sure.'
                self._send({'id': 'x', 'object': 'chat.completion', 'created': 0, 'model': 'default_model',
                            'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': answer}, 'finish_reason': 'stop'}],
                            'usage': {'prompt_tokens': 5, 'completion_tokens': 3, 'total_tokens': 8}})
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
    def close(self): self.server.shutdown(); self.server.server_close()


class ImportTests(unittest.TestCase):
    def test_csv_jsonl_json_and_task_files(self):
        csv = parse_import(dict(name='capitals.csv', text='question,answer\nCapital of France?,Paris\nWhat is 2+2?,4\n'))
        self.assertEqual(csv['draft']['kind'], 'dataset')
        self.assertEqual(csv['draft']['dataset'][0], dict(input='Capital of France?', target='Paris'))
        self.assertEqual(csv['draft']['title'], 'capitals')
        jsonl = parse_import(dict(name='x.jsonl', text='{"input": "A?", "target": "a", "choices": ["a", "b"]}\n{"input": "B?", "target": "b", "choices": ["a", "b"]}\n'))
        self.assertEqual((jsonl['draft']['scorer']['kind'], jsonl['draft']['solver']['kind']), ('choice', 'multiple_choice'))
        js = parse_import(dict(name='x.json', text=json.dumps({'samples': [{'prompt': 'Hi', 'expected': 'hello', 'level': 2}]})))
        self.assertEqual(js['draft']['dataset'][0]['metadata'], {'level': 2})
        task = parse_import(dict(name='mine.py', text='from inspect_ai import task\n@task\ndef capitals():\n    pass\n'))
        self.assertEqual((task['draft']['kind'], task['draft']['task_file']['task']), ('task_file', 'capitals'))
        self.assertIn('Python code', task['warnings'][0])
        for bad in ['', 'not, a\n', '{"nope": 1}', 'print("no task")']:
            with self.assertRaises(ValueError): parse_import(dict(name='x', text=bad))


@unittest.skipUnless(available()[0], 'Inspect AI is not installed (uv run --extra evals)')
class InspectRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = SandboxRuns(Path(self.tmp.name) / 'lab')
        self.inspect = self.runs.evals.inspect
        self.chat = FakeChat()

    def tearDown(self):
        self.chat.close(); self.tmp.cleanup()

    def wait(self, run_id, timeout=180):
        end = time.time() + timeout
        while time.time() < end:
            r = self.inspect.run(run_id)
            if r['status'] not in ('running',): return r
            time.sleep(0.5)
        self.fail('Inspect run did not finish')

    def test_build_run_and_see_it_in_the_evals_overview(self):
        d = self.inspect.save_def(dict(kind='dataset', title='Capitals', epochs=2, solver=dict(kind='generate'), scorer=dict(kind='includes'),
                                       dataset=[dict(input='Capital of France?', target='Paris'), dict(input='What is 2+2?', target='4'),
                                                dict(input='Capital of Peru?', target='Lima')]))
        self.assertEqual(self.inspect.defs()[0]['samples'], 3)
        with self.assertRaises(ValueError): self.inspect.start_run(dict(def_=d['id'], models=[]))
        run = self.inspect.start_run({'def': d['id'], 'models': [dict(port=self.chat.port, model='default_model', label='Fake 1B')]})
        r = self.wait(run['id'])
        m = r['models'][0]
        self.assertEqual(r['status'], 'done', m.get('error'))
        self.assertEqual((m['n'], m['pass'], m['done'], m['total']), (6, 4, 6, 6))  # 3 samples × 2 epochs; Lima missed
        self.assertAlmostEqual(m['accuracy'], 4 / 6, places=3)
        self.assertEqual(len(m['ci']), 2)
        self.assertTrue(Path(m['log']).exists() and m['log'].endswith('.eval'))  # Inspect's own log
        self.assertEqual({s['passed'] for s in m['samples'] if s['input'] == 'Capital of Peru?'}, {False})
        cell = self.runs.evals.overview()['inspect'][0]
        self.assertEqual((cell['title'], cell['label'], cell['pass'], cell['n']), ('Capitals', 'Fake 1B', 4, 6))

    def test_judge_scored_eval_uses_the_chosen_grader(self):
        d = self.inspect.save_def(dict(kind='dataset', title='Judged', solver=dict(kind='generate'), scorer=dict(kind='model_graded_qa'),
                                       dataset=[dict(input='Capital of France?', target='Paris')]))
        model = dict(port=self.chat.port, model='default_model')
        with self.assertRaises(ValueError): self.inspect.start_run({'def': d['id'], 'models': [model]})  # needs a judge
        r = self.wait(self.inspect.start_run({'def': d['id'], 'models': [model], 'grader': model})['id'])
        self.assertEqual(r['status'], 'done', r['models'][0].get('error'))
        self.assertEqual(r['models'][0]['pass'], 1)

    def test_definitions_are_validated(self):
        for bad in [dict(kind='dataset', title='x', dataset=[]), dict(kind='dataset', title='', dataset=[dict(input='a')]),
                    dict(kind='dataset', title='x', dataset=[dict(input='a')], scorer=dict(kind='pattern', pattern='(')),
                    dict(kind='library', title='x', library=dict(id='inspect_evals/unknown')), dict(kind='task_file', title='x', task_file=dict(code='x=1'))]:
            with self.assertRaises(ValueError): self.inspect.save_def(bad)


if __name__ == '__main__':
    unittest.main()
