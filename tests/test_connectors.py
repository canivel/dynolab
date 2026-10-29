import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

try:
    import mcp  # noqa: F401
except ImportError:  # the connectors need the mcp extra
    mcp = None

from dyno.lab.assistant import Assistant
from dyno.lab.connectors import Connectors
from test_assistant import FakeRuns, ScriptedModel

SERVER = str(Path(__file__).with_name('fake_mcp_server.py'))


class MemoryKeychain:
    def __init__(self): self.items = {}
    def get(self, service, account): return self.items.get((service, account))
    def set(self, service, account, value): self.items[(service, account)] = value
    def delete(self, service, account): self.items.pop((service, account), None)


class ConnectorListTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.keychain = MemoryKeychain()
        self.c = Connectors(Path(self.tmp.name), keychain=self.keychain)

    def tearDown(self):
        self.c.stop_all(); self.tmp.cleanup()

    def test_secrets_go_to_the_keychain_never_the_file(self):
        x = self.c.save(dict(name='GitHub', command='npx', args=['-y', 'server-github'], env={'GITHUB_TOKEN': 'ghp_secret123'}))
        self.assertNotIn('ghp_secret123', self.c.path.read_text())
        self.assertNotIn('ghp_secret123', json.dumps(self.c.list()))
        self.assertEqual(x['env_keys'], ['GITHUB_TOKEN'])
        # Editing without the value keeps it; leaving the key out removes it.
        self.c.save(dict(id=x['id'], name='GitHub', command='npx', env={'GITHUB_TOKEN': None}))
        self.assertEqual(list(self.keychain.items.values()), ['ghp_secret123'])
        self.c.save(dict(id=x['id'], name='GitHub', command='npx', env={}))
        self.assertEqual(self.keychain.items, {})

    def test_a_claude_desktop_config_pastes_in(self):
        r = self.c.import_config(dict(json=json.dumps({'mcpServers': {
            'filesystem': {'command': 'npx', 'args': ['-y', '@modelcontextprotocol/server-filesystem', '/tmp']},
            'linear': {'type': 'http', 'url': 'https://mcp.linear.app/mcp', 'headers': {'Authorization': 'Bearer abc'}}}})))
        got = {x['name']: x for x in r['added']}
        self.assertEqual(got['filesystem']['transport'], 'stdio')
        self.assertEqual(got['linear']['transport'], 'http')
        self.assertTrue(got['linear']['remote'])
        self.assertEqual(got['linear']['headers_keys'], ['Authorization'])
        self.assertNotIn('Bearer abc', self.c.path.read_text())

    def test_bad_input_is_explained(self):
        for body, message in ((dict(name='', command='npx'), 'name'), (dict(name='x', transport='stdio'), 'command'),
                              (dict(name='x', transport='http', url='ftp://x'), 'https'),
                              (dict(name='x', command='npx', env={'BAD KEY': 'v'}), 'variable')):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, message): self.c.save(body)
        with self.assertRaisesRegex(ValueError, 'valid JSON'): self.c.import_config(dict(json='{nope'))

    def test_two_connectors_with_the_same_name_get_different_prefixes(self):
        a, b = self.c.save(dict(name='Notes', command='x')), self.c.save(dict(name='Notes', command='y'))
        self.assertNotEqual(a['prefix'], b['prefix'])


@unittest.skipIf(mcp is None, 'needs the mcp extra')
class ConnectorServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.c = Connectors(Path(self.tmp.name), keychain=MemoryKeychain())

    def tearDown(self):
        self.c.stop_all(); self.tmp.cleanup()

    def test_lists_and_calls_tools_with_the_saved_environment(self):
        x = self.c.save(dict(name='Notes', command=sys.executable, args=[SERVER], env={'NOTES_TOKEN': 'tok-1'}, allow_reads=True))
        tools, problems = self.c.tools([x['id']])
        self.assertEqual(problems, [])
        self.assertEqual({n: t['read_only'] for n, t in tools.items()},
                         {'notes__search_notes': True, 'notes__add_note': False, 'notes__whoami': True, 'notes__broken': False})
        self.assertEqual(self.c.call(x['id'], 'search_notes', dict(query='probe')), 'probe results on layer 12')
        self.assertEqual(self.c.call(x['id'], 'whoami', {}), 'tok-1')
        with self.assertRaisesRegex(ValueError, 'locked'): self.c.call(x['id'], 'broken', {})

    def test_reads_ask_first_unless_the_person_allowed_them(self):
        x = self.c.save(dict(name='Notes', command=sys.executable, args=[SERVER]))
        tools, _ = self.c.tools([x['id']])
        self.assertFalse(any(t['read_only'] for t in tools.values()))

    def test_a_server_that_fails_says_why(self):
        missing = self.c.save(dict(name='Missing', command='no-such-command-dyno'))
        dies = self.c.save(dict(name='Dies', command=sys.executable, args=['-c', 'import sys; print("missing API key", file=sys.stderr); sys.exit(1)']))
        tools, problems = self.c.tools([missing['id'], dies['id']])
        self.assertEqual(tools, {})
        self.assertIn("Couldn't find the command", problems[0])
        self.assertIn('missing API key', problems[1])

    def test_stopping_ends_the_server(self):
        x = self.c.save(dict(name='Notes', command=sys.executable, args=[SERVER]))
        self.c.tools([x['id']])
        link = self.c.links[x['id']]
        self.c.stop_all()
        self.assertTrue(link.done.is_set())
        self.assertEqual(self.c.list()['connectors'][0]['status'], 'stopped')


@unittest.skipIf(mcp is None, 'needs the mcp extra')
class AssistantConnectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.a = Assistant(FakeRuns(Path(self.tmp.name)))
        self.a.connectors.keychain = MemoryKeychain()
        self.models = []

    def tearDown(self):
        for m in self.models: m.close()
        self.a.connectors.stop_all(); self.tmp.cleanup()

    def wait(self, cid, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            c = self.a.get(cid)
            if c['conversation']['status'] in ('idle', 'waiting'): return c
            time.sleep(0.05)
        self.fail('the assistant did not finish')

    def test_reads_run_at_once_and_changes_wait_for_approval(self):
        x = self.a.connectors.save(dict(name='Notes', command=sys.executable, args=[SERVER], allow_reads=True))
        m = ScriptedModel([dict(calls=[('notes__search_notes', dict(query='eval'))]),
                           dict(calls=[('notes__add_note', dict(text='GHOST run 3 refused'))]),
                           dict(content='Saved the note.')])
        self.models.append(m)
        cid = self.a.create()['id']
        self.a.settings(cid, dict(connectors=[x['id']]))
        self.a.message(cid, dict(text='Find my eval notes, then save one.', model=dict(port=m.port, model='qwen')))
        c = self.wait(cid)
        names = {t['function']['name'] for t in m.requests[0]['tools']}
        self.assertIn('notes__search_notes', names)
        self.assertIn('## Connectors', m.requests[0]['messages'][0]['content'])
        result = next(e for e in c['events'] if e['kind'] == 'tool_result' and e['name'] == 'notes__search_notes')
        self.assertEqual(result['content'], 'eval batch notes')
        self.assertEqual(c['pending']['name'], 'notes__add_note')
        self.assertIn('Notes', c['pending']['summary'])
        self.a.decide(cid, dict(proposal=c['pending']['id'], approve=True))
        c = self.wait(cid)
        done = next(e for e in c['events'] if e['kind'] == 'decision')
        self.assertTrue(done['ok'])
        self.assertIn('saved (3 notes)', done['result'])

    def test_connector_tools_are_only_sent_when_the_conversation_has_them_on(self):
        self.a.connectors.save(dict(name='Notes', command=sys.executable, args=[SERVER]))
        m = ScriptedModel([dict(content='Hi.')]); self.models.append(m)
        cid = self.a.create()['id']
        self.a.message(cid, dict(text='Hello', model=dict(port=m.port, model='qwen')))
        self.wait(cid)
        self.assertFalse(any('__' in t['function']['name'] for t in m.requests[0]['tools']))
        with self.assertRaisesRegex(ValueError, 'Unknown connector'): self.a.settings(cid, dict(connectors=['nope']))


if __name__ == '__main__':
    unittest.main()
