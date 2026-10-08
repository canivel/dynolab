import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from dyno.lab.assistant import Assistant


class ScriptedModel:
    """An OpenAI-compatible local server that streams scripted replies, one per request, and keeps every request."""
    def __init__(self, replies):
        self.replies, self.requests = list(replies), []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                outer.requests.append(req)
                reply = outer.replies.pop(0) if outer.replies else dict(content='(no more replies)')
                if not req.get('stream'):
                    body = json.dumps(dict(choices=[dict(message=dict(role='assistant', content=reply.get('content', '')), finish_reason='stop')])).encode()
                    self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                def send(obj): self.wfile.write(f'data: {json.dumps(obj)}\n\n'.encode()); self.wfile.flush()
                self.wfile.write(b': keepalive 1/2\n\n')
                for piece in (reply.get('reasoning') or '').split(' '):
                    if piece: send(dict(choices=[dict(index=0, delta=dict(reasoning=piece + ' '))]))
                for piece in (reply.get('content') or '').split(' '):
                    if piece: send(dict(choices=[dict(index=0, delta=dict(content=piece + ' '))]))
                for i, (name, args) in enumerate(reply.get('calls') or []):
                    send(dict(choices=[dict(index=0, delta=dict(tool_calls=[dict(index=i, id=f'call{len(outer.requests)}_{i}', type='function',
                                                                                function=dict(name=name, arguments=json.dumps(args)))]))]))
                send(dict(choices=[dict(index=0, delta={}, finish_reason='tool_calls' if reply.get('calls') else 'stop')],
                          usage=dict(prompt_tokens=reply.get('prompt_tokens', 1000), completion_tokens=10)))
                self.wfile.write(b'data: [DONE]\n\n')

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self): self.server.shutdown(); self.server.server_close()


class FakeEvals:
    def __init__(self): self.batches = []
    def overview(self): return dict(scenarios=[], configs=[], cells=[], inspect=[], unfinished=0)
    def start_batch(self, body): self.batches.append(body); return dict(id='b' * 32, total=body['repeats'] * len(body['models']), status='running')


class FakeRuns:
    """The parts of the lab the assistant calls."""
    def __init__(self, root):
        self.root = root / 'sandbox-runs'; self.root.mkdir(parents=True)
        self.started, self.evals = [], FakeEvals()
    def environments(self, d): return dict(templates=[dict(id='ghost-long-horizon', meta=dict(title='GHOST', description='Orders API'),
                                                            gateway=[dict(host='api.internal', port=8080, action='flag')])])
    def _room_spec(self, spec, complete=True):
        if not spec.get('goal'): raise ValueError('Write a goal')
        if complete and not all(a.get('port') for a in spec.get('agents') or [{}]): raise ValueError('Choose a running model for every agent')
        return spec
    def room_plan(self, body): return dict(errors=[], warnings=[], rules=[dict(n=1, text=r['text'], watch=dict(kind='report')) for r in body['spec'].get('rules', [])])
    def create(self, config): self.started.append(config); return dict(id='r' * 32, status='running')


SPEC = dict(title='Keeps a rule', environment='ghost-long-horizon', goal='Send a test order.', rules=[dict(text='Staging only.')],
            agents=[dict(name='Lead Agent', role='team lead', port=8971, model='qwen')], limits=dict(team_size=1))


class AssistantTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = FakeRuns(Path(self.tmp.name))
        self.a = Assistant(self.runs)
        self.models = []

    def tearDown(self):
        for m in self.models: m.close()
        self.tmp.cleanup()

    def model(self, replies):
        m = ScriptedModel(replies); self.models.append(m); return m

    def wait(self, cid, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            c = self.a.get(cid)
            if c['conversation']['status'] in ('idle', 'waiting'): return c
            time.sleep(0.05)
        self.fail('the assistant did not finish')

    def send(self, cid, m, text, context=None):
        return self.a.message(cid, dict(text=text, model=dict(port=m.port, model='qwen'), context=context or {}))

    def test_looks_then_answers_and_never_sends_its_thinking_back(self):
        m = self.model([dict(reasoning='I should list them first.', calls=[('list_environments', {})]),
                        dict(content='You have one environment: GHOST.')])
        cid = self.a.create()['id']
        self.send(cid, m, 'Which environments do I have?', dict(screen='Agents · Setup', running_models=[dict(port=8971, model='qwen')]))
        c = self.wait(cid)
        kinds = [e['kind'] for e in c['events']]
        self.assertEqual(kinds, ['user', 'assistant', 'tool_result', 'assistant'])
        self.assertIn('ghost-long-horizon', c['events'][2]['content'])
        self.assertEqual(c['events'][1]['reasoning'].strip(), 'I should list them first.')  # kept on disk for the person
        second = m.requests[1]['messages']
        self.assertNotIn('I should list them first', json.dumps(second))  # but never sent back to the model
        self.assertEqual([x['role'] for x in second], ['system', 'user', 'assistant', 'tool'])
        self.assertIn('Agents · Setup', second[0]['content'])  # what the person sees is part of the prompt
        self.assertTrue(m.requests[0]['tools'] and m.requests[0]['stream'])
        self.assertEqual(c['conversation']['title'], 'Which environments do I have?')

    def test_acting_waits_for_the_person_and_only_the_click_runs_it(self):
        m = self.model([dict(content='Here is the test.', calls=[('show_test_setup', dict(spec=SPEC)), ('start_test', dict(spec=SPEC))]),
                        dict(content='It is running. Watch it in Agents → Room & Observer.'),
                        dict(content='Started.', calls=[('start_test', dict(spec=SPEC))]),
                        dict(content='OK, not running it. What should change?')])
        cid = self.a.create()['id']
        self.send(cid, m, 'Test whether the model keeps a staging-only rule.')
        c = self.wait(cid)
        self.assertEqual(c['conversation']['status'], 'waiting')
        self.assertEqual(c['pending']['name'], 'start_test')
        self.assertIn('Keeps a rule', c['pending']['summary'])
        self.assertEqual(next(e for e in c['events'] if e['kind'] == 'ui')['action'], 'show_test_setup')
        self.assertEqual(self.runs.started, [])  # nothing ran yet
        with self.assertRaises(ValueError): self.a.decide(cid, dict(proposal='nope', approve=True))
        self.a.decide(cid, dict(proposal=c['pending']['id'], approve=True))
        c = self.wait(cid)
        self.assertEqual(len(self.runs.started), 1)
        self.assertEqual(self.runs.started[0]['spec']['goal'], 'Send a test order.')
        self.assertIn('Approved and done', next(e for e in c['events'] if e['kind'] == 'tool_result' and e['name'] == 'start_test')['content'])
        self.assertIsNone(c['pending'])
        # A second proposal, then the person writes instead of clicking: it is not run, and the call still gets its answer.
        self.send(cid, m, 'Start it again')
        c = self.wait(cid)
        pid = c['pending']['id']
        self.send(cid, m, 'Actually, wait.')
        c = self.wait(cid)
        self.assertEqual(len(self.runs.started), 1)
        self.assertTrue(any(e['kind'] == 'decision' and e['proposal'] == pid and not e['approve'] for e in self.a._events(cid)))
        sent = m.requests[-1]['messages']
        calls = {c['id'] for x in sent if x['role'] == 'assistant' for c in x.get('tool_calls') or []}
        answered = {x['tool_call_id'] for x in sent if x['role'] == 'tool'}
        self.assertEqual(calls, answered)  # every tool call the model made has a result, so the chat format stays valid

    def test_bad_setups_are_sent_back_not_shown_or_proposed(self):
        m = self.model([dict(calls=[('show_test_setup', dict(spec=dict(goal=''))), ('start_test', dict(spec=dict(SPEC, agents=[dict(name='A')]))),
                                    ('save_prompt', dict(name='Careful', lead='Lead.', teammate='', team='')),
                                    ('start_eval_batch', dict(spec=SPEC, models=[], repeats=3)),
                                    ('save_inspect_eval', dict(definition=dict(kind='task_file', title='x', task_file=dict(code='@task')))),
                                    ('run_inspect_eval', dict(def_id='', models=[dict(port=1, model='m')]))]),
                        dict(content='Let me fix that.')])
        cid = self.a.create()['id']
        self.send(cid, m, 'Set it up')
        c = self.wait(cid)
        results = [e['content'] for e in c['events'] if e['kind'] == 'tool_result']
        self.assertEqual(len(results), 6)
        self.assertTrue(all(r.startswith('error: ') for r in results), results)
        self.assertIn('teammate', results[2]); self.assertIn('task files', results[4])

    def test_an_unknown_environment_is_sent_back_with_the_real_ones(self):
        m = self.model([dict(calls=[('show_test_setup', dict(spec=dict(SPEC, environment='segmented_office')))]), dict(content='Fixed.')])
        cid = self.a.create()['id']
        self.send(cid, m, 'Set it up'); c = self.wait(cid)
        result = next(e['content'] for e in c['events'] if e['kind'] == 'tool_result')
        self.assertIn("no environment 'segmented_office'", result); self.assertIn('ghost-long-horizon', result)
        self.assertFalse(any(e['kind'] == 'ui' for e in c['events']))
        self.assertFalse(any(e['kind'] in ('ui', 'proposal') for e in c['events']))

    def test_the_task_list_is_kept_and_always_in_the_prompt(self):
        m = self.model([dict(calls=[('update_plan', dict(steps=[dict(title='Pick an environment', status='doing'), dict(title='Run 5 times')]))]),
                        dict(content='First, the environment.'), dict(content='Next.')])
        cid = self.a.create()['id']
        self.send(cid, m, 'Plan it')
        c = self.wait(cid)
        self.assertEqual(c['conversation']['plan'], [dict(title='Pick an environment', status='doing'), dict(title='Run 5 times', status='todo')])
        self.send(cid, m, 'go on'); self.wait(cid)
        self.assertIn('[doing] Pick an environment', m.requests[-1]['messages'][0]['content'])

    def test_a_long_conversation_stays_within_the_budget(self):
        big = 'x' * 12000  # each look returns a large result
        replies = []
        for i in range(8):
            replies += [dict(calls=[('app_state', {})]), dict(content=f'Answer {i}. ' + 'detail ' * 300)]
        replies.append(dict(content='The person wants to compare two models on a staging-only rule; one test started.'))  # the summary
        replies += [dict(content='Answer 8.')] * 3
        m = self.model(replies)
        cid = self.a.create()['id']
        self.a.settings(cid, dict(budget=8192))
        for i in range(8):
            self.send(cid, m, f'Question {i}: ' + 'words ' * 200, dict(screen='Evals', blob=big[:3000]))
            self.wait(cid)
        self.send(cid, m, 'And now?'); c = self.wait(cid)
        events = self.a._events(cid)
        summary = [e for e in events if e['kind'] == 'summary']
        self.assertEqual(len(summary), 1)
        self.assertIn('compare two models', summary[0]['text'])
        last = m.requests[-1]['messages']
        self.assertIn('Earlier in this conversation', last[0]['content'])
        self.assertNotIn('Question 0:', json.dumps(last))  # folded into the summary
        use = self.a._meta(cid)['context_use']
        self.assertLessEqual(use['estimated_tokens'], 8192 - 4096)
        self.assertEqual(len([e for e in events if e['kind'] == 'user']), 9)  # the log on disk keeps everything
        # Reopening reads a page, not the whole history.
        page = self.a.get(cid, limit=10)
        self.assertEqual(len(page['events']), 10); self.assertTrue(page['earlier'])
        older = self.a.get(cid, before=page['events'][0]['seq'], limit=500)
        self.assertGreater(len(older['events']), 10)

    def test_old_tool_results_become_stubs(self):
        a = self.a
        cid = a.create()['id']
        for i in range(3):
            a._append(cid, 'user', text=f'q{i}', context={})
            a._append(cid, 'assistant', text='', tool_calls=[dict(id=f'c{i}', name='list_tests', arguments='{}')])
            a._append(cid, 'tool_result', call=f'c{i}', name='list_tests', content='y' * 5000)
        meta = a._meta(cid); meta['model'] = dict(port=1, model='m'); a._save_meta(cid, meta)
        tools = [m['content'] for m in a._prompt(cid) if m['role'] == 'tool']
        self.assertTrue(tools[0].startswith('[list_tests result from earlier'))
        self.assertEqual(len(tools[-1]), 5000)

    def test_only_a_local_model_and_conversations_survive_a_restart(self):
        for bad in [None, dict(port='8971', model='q'), dict(port=8971), dict(port=0, model='q'), dict(base_url='https://api.example.com', model='q')]:
            with self.assertRaises(ValueError): self.a._model(bad)
        cid = self.a.create()['id']
        with self.assertRaises(ValueError): self.a.message(cid, dict(text='hi', model=dict(base_url='https://api.example.com', model='q')))
        m = self.model([dict(content='Hello.')])
        self.send(cid, m, 'hi'); self.wait(cid)
        meta = self.a._meta(cid); meta['status'] = 'thinking'; self.a._save_meta(cid, meta)  # as if the lab died mid-turn
        again = Assistant(self.runs)
        c = again.get(cid)
        self.assertEqual(c['conversation']['status'], 'idle')
        self.assertEqual([e['kind'] for e in c['events']], ['user', 'assistant', 'error'])
        self.assertEqual(again.list()['conversations'][0]['id'], cid)
        self.assertEqual(json.loads((again.folder / cid / 'meta.json').read_text())['model']['port'], m.port)
        again.delete(cid)
        self.assertEqual(again.list()['conversations'], [])

    def test_an_empty_reply_is_retried_and_text_tool_calls_are_read(self):
        from dyno.lab.assistant import _text_tool_calls
        rest, calls = _text_tool_calls('Let me look.\n<tool_call>{"name": "list_tests", "arguments": {"limit": 3}}</tool_call>')
        self.assertEqual((rest, calls[0]['name'], json.loads(calls[0]['arguments'])), ('Let me look.', 'list_tests', {'limit': 3}))
        self.assertEqual(_text_tool_calls('<tool_call>{broken</tool_call>')[1], [])
        m = self.model([dict(content=''), dict(content='Here you go.')])
        cid = self.a.create()['id']
        self.send(cid, m, 'hi'); c = self.wait(cid)
        self.assertEqual([e['text'].strip() for e in c['events'] if e['kind'] == 'assistant'], ['Here you go.'])
        self.assertEqual([r['temperature'] for r in m.requests], [0.3, 0.0])

    def test_calibrates_tokens_on_what_the_server_counted(self):
        m = self.model([dict(content='ok', prompt_tokens=100)])
        cid = self.a.create()['id']
        self.send(cid, m, 'hi'); self.wait(cid)
        self.assertGreater(self.a._meta(cid)['chars_per_token'], 3.2)  # a short prompt with many characters per counted token


if __name__ == '__main__':
    unittest.main()
