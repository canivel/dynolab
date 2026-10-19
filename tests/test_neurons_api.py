"""The neuron operations through the SDK, the MCP bridge and the OpenAPI document, against the real Lab handler.

No model runs: submissions are validated and recorded, and finished jobs are written to disk as the worker would."""
import gzip
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

from dyno.lab.server import Handler, Jobs, validate
from dyno.sdk import DynoError, Lab

try:
    import mcp  # noqa: F401
    HAS_MCP = True
except ImportError:
    HAS_MCP = False

CAPTURE, ATLAS, SAE, AUTOINTERP, RUNNING = 'a' * 32, 'b' * 32, 'c' * 32, 'd' * 32, 'e' * 32
VOCAB = {'1': 'The', '2': ' cat', '3': ' sat', '4': ' Santa'}
EXAMPLE = dict(value=4.0, fraction=1.0, ids=[1, 2, 3], activations=[0.1, 4.0, 0.2], center=1, context=0, position=1)
PAGE = dict(unit=0, kind='neuron', index=0, edges=[0.01], mean=0.1, std=0.5,
            poles=dict(positive=dict(maximum=4.0, per_100_tokens={'10%': 2.0, '25%': 1.0, '50%': 0.5}, histogram=[0, 1],
                                     top=[EXAMPLE], stratified=[dict(decile=9, range=[0.9, 1.0], examples=[EXAMPLE])], heldout_top=[EXAMPLE]),
                       negative=dict(maximum=1.5, per_100_tokens={'10%': 1.0, '25%': 0.5, '50%': 0.1}, histogram=[0, 1],
                                     top=[dict(EXAMPLE, value=-1.5, ids=[4, 3], activations=[-1.5, 0.0], center=0)], stratified=[], heldout_top=[])),
            random=[dict(EXAMPLE, value=0.1)], heldout_random=[])
INDEX = dict(layer=14, hook='mlp_hidden', tokens=2000, units=[
    dict(unit=0, kind='neuron', index=0, positive=dict(maximum=4.0, per_100_tokens={}, preview=[' cat']), negative=dict(maximum=1.5, per_100_tokens={}, preview=[' Santa'])),
    dict(unit=1, kind='neuron', index=1, positive=dict(maximum=9.0, per_100_tokens={}, preview=[]), negative=dict(maximum=0.5, per_100_tokens={}, preview=[])),
    dict(unit=2, kind='random', index=0, positive=dict(maximum=1.0, per_100_tokens={}, preview=[]), negative=dict(maximum=3.0, per_100_tokens={}, preview=[]))])
ROWS = [dict(layer=14, unit=0, kind='neuron', index=0, pole='positive', label='the word cat', detection=dict(balanced_accuracy=0.9)),
        dict(layer=14, unit=0, kind='neuron', index=0, pole='negative', label='Santa', detection=dict(balanced_accuracy=0.6)),
        dict(layer=14, unit=2, kind='random', index=0, pole='positive', label='spaces', detection=dict(balanced_accuracy=0.5))]


def finished(root, identifier, operation, result, files=None):
    folder = Path(root) / identifier
    folder.mkdir()
    for name, content in (files or {}).items():
        (folder / name).parent.mkdir(parents=True, exist_ok=True)
        (folder / name).write_bytes(content if isinstance(content, bytes) else json.dumps(content).encode())
    artifacts = sorted(n for n in (files or {}) if '/' not in n)
    Jobs.write(folder / 'job.json', dict(id=identifier, created=0, status='completed', operation=operation, model='mlx-community/Qwen3-0.6B-8bit',
                                         config={}, result=dict(result, artifacts=artifacts)))


def lab_server(root):
    jobs = Jobs(root)
    finished(root, CAPTURE, 'capture', {'capture': {'tokens': 2000}})
    finished(root, ATLAS, 'atlas', {'atlas': {'capture': CAPTURE}}, {
        'atlas/index-L14.json': INDEX, 'atlas/vocab-L14.json': VOCAB, 'atlas/L14/0.json.gz': gzip.compress(json.dumps(PAGE).encode())})
    finished(root, SAE, 'sae_train', {'reports': []}, {'sae-alignment.json': {'summary': {'live_features': 2}, 'features': [], 'neurons': []}})
    finished(root, AUTOINTERP, 'autointerp', {'autointerp': {'summary': {'neuron': {'detection': {'pass_rate': 0.5}}}, 'templates': {'explain': 'x'}}},
             {'autointerp.json': {'rows': ROWS, 'settings': {}}})
    submissions = []

    def submit(config):
        submissions.append(validate(config))
        return dict(id='f' * 32, status='queued', operation=config['operation'], config=config)
    jobs.submit = submit  # No GPU work: check what would be submitted.
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.jobs = jobs
    from dyno.lab.neurons.recipes import Recipes
    server.recipes = Recipes(root, jobs)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def stop():
        server.shutdown(); server.server_close(); thread.join(); jobs._directory_lock.close()
    return server, jobs, submissions, stop


class NeuronSDK(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = self.directory.name
        self.server, self.jobs, self.submissions, stop = lab_server(self.root)
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(stop)
        self.lab = Lab(f'http://127.0.0.1:{self.server.server_port}')

    def test_submissions_reach_the_lab_as_valid_jobs(self):
        lab, model = self.lab, 'mlx-community/Qwen3-0.6B-8bit'
        self.assertIn('autointerp', lab.health()['operations'])
        lab.capture(model, [14], tokens=2_000_000, units={'neurons': 'all', 'random_directions': 20})
        lab.atlas(CAPTURE)
        lab.sae_train(model, 14, architecture='batchtopk', tokens=20_000_000)
        lab.ablate(model, layers=[14])
        lab.attribute(model, 'Who brings presents at Christmas? It is', ' Santa', layers=[14])
        lab.ablate_units(model, 'Who brings presents at Christmas? It is', ' Santa', [(14, 3), [14, 7]])
        lab.steer(model, 'The weather today is', [14, 3], strengths=[0, 2], atlas=ATLAS)
        lab.autointerp(ATLAS, 8083, {'port': 8084, 'model': 'scorer'}, condition='improved')
        lab.probe(model, [], layers=[14], hook='mlp_hidden')
        lab.inspect(model, 'hello', layers=[14])
        s = self.submissions
        self.assertEqual([x['operation'] for x in s], ['capture', 'atlas', 'sae_train', 'ablate', 'units', 'units', 'units', 'autointerp', 'probe', 'inspect'])
        self.assertEqual((s[0]['corpus'], s[0]['layers']), ('web-mix', [14]))
        self.assertEqual((s[1]['model'], s[1]['capture']), (model, CAPTURE))  # the capture's model
        self.assertEqual(s[2]['layers'], [14])
        self.assertEqual([s[4]['mode'], s[5]['mode'], s[6]['mode']], ['attribute', 'ablate_set', 'steer'])
        self.assertEqual(s[5]['units'], [[14, 3], [14, 7]])
        self.assertEqual((s[6]['unit'], s[6]['strengths']), ([14, 3], [0, 2]))
        self.assertNotIn('model', s[7])
        self.assertEqual((s[7]['explainer'], s[7]['scorer']['port']), ({'port': 8083}, 8084))
        self.assertEqual(s[8]['hook'], 'mlp_hidden')
        self.assertNotIn('hook', s[9])
        with self.assertRaises(DynoError):
            lab.capture(model, list(range(9)))

    def test_recipes_are_listed_and_checked_before_they_start(self):
        listed = self.lab.recipes()
        self.assertEqual(set(listed['builtins']), {'already-clean-fast', 'already-clean-full'})
        self.assertEqual([s['operation'] for s in listed['builtins']['already-clean-fast']['steps']][:3], ['capture', 'atlas', 'autointerp'])
        with self.assertRaises(DynoError):  # auto-interp steps need the scoring models
            self.lab.run_recipe('already-clean-fast', 'mlx-community/Qwen3-0.6B-8bit')
        with self.assertRaises(DynoError):  # a step can only use earlier steps
            self.lab.run_recipe(dict(title='x', steps=[dict(name='atlas', config=dict(operation='atlas', capture='${capture}'))]), 'm')
        with self.assertRaises(DynoError):  # not a later one either
            self.lab.run_recipe(dict(title='x', steps=[dict(name='a', config=dict(operation='atlas', capture='${c}')),
                                                       dict(name='c', config=dict(operation='capture', layers=[1], corpus='web-mix'))]), 'm')
        with self.assertRaises(DynoError):  # every step's settings are checked up front
            self.lab.run_recipe(dict(title='x', steps=[dict(name='c', config=dict(operation='capture', layers=[1], corpus='nope'))]), 'm')
        self.assertEqual(self.submissions, [])

    def test_atlas_pages_rows_and_alignment(self):
        lab = self.lab
        self.assertEqual([u['unit'] for u in lab.atlas_index(ATLAS, 14)['units']], [0, 1, 2])
        self.assertEqual(lab.atlas_vocab(ATLAS, 14), VOCAB)
        self.assertEqual(lab.atlas_unit(ATLAS, 14, 0), PAGE)  # served gzip-encoded
        page = lab.atlas_unit(ATLAS, 14, 0, text=True)
        top = page['poles']['positive']['top'][0]
        self.assertEqual((top['text'], top['token']), ('The cat sat', ' cat'))
        self.assertEqual(page['poles']['negative']['top'][0]['token'], ' Santa')
        self.assertEqual(page['poles']['positive']['stratified'][0]['examples'][0]['token'], ' cat')
        self.assertEqual(page['random'][0]['text'], 'The cat sat')
        for missing in ((ATLAS, 3, 0), (ATLAS, 14, 99), (CAPTURE, 14, 0)):
            with self.assertRaises(DynoError): lab.atlas_unit(*missing)
        self.assertEqual(lab.autointerp_rows(AUTOINTERP), ROWS)
        self.assertEqual(lab.sae_alignment(SAE)['summary']['live_features'], 2)

    def test_wait_reports_progress(self):
        folder = Path(self.root) / RUNNING
        folder.mkdir()
        Jobs.write(folder / 'job.json', dict(id=RUNNING, created=0, status='running', operation='capture', model='m', config={}))
        (folder / 'progress.json').write_text(json.dumps(dict(message='1,000 of 2,000 tokens', fraction=0.5, eta_seconds=10, updated=1)))
        seen = []

        def progress(p):
            seen.append(p['message'])
            Jobs.write(folder / 'job.json', dict(id=RUNNING, created=0, status='completed', operation='capture', model='m', config={}, result={}))
        self.assertEqual(self.lab.wait(RUNNING, timeout=10, interval=0.01, progress=progress)['status'], 'completed')
        self.assertEqual(seen, ['1,000 of 2,000 tokens'])


class NeuronOpenAPI(unittest.TestCase):
    def test_documents_neuron_jobs_atlas_pages_and_progress(self):
        schema = json.loads((Path(__file__).resolve().parents[1] / 'src/dyno/lab/openapi.json').read_text())
        from dyno.lab.neurons.hooks import HOOKS
        from dyno.lab.neurons.jobs import OPERATIONS as NEURON_OPERATIONS
        from dyno.lab.server import OPERATIONS
        body = schema['paths']['/jobs']['post']['requestBody']['content']['application/json']['schema']
        self.assertEqual(set(body['discriminator']['mapping']), set(OPERATIONS))
        components = schema['components']['schemas']
        for reference in body['discriminator']['mapping'].values():
            self.assertIn(reference.rsplit('/', 1)[-1], components)
        self.assertEqual(components['ExperimentJob']['properties']['hook']['enum'], list(HOOKS))
        for name, operation in zip(('CaptureJob', 'AtlasJob', 'SaeTrainJob', 'AblateJob', 'UnitsJob', 'AutointerpJob'), NEURON_OPERATIONS):
            self.assertEqual(components[name]['properties']['operation']['enum'], [operation])
        self.assertIn('/jobs/{id}/atlas/{layer}/{page}', schema['paths'])
        self.assertIn('progress', components['Job']['properties'])

        def refs(node):
            if isinstance(node, dict):
                if '$ref' in node: yield node['$ref']
                for value in node.values(): yield from refs(value)
            elif isinstance(node, list):
                for value in node: yield from refs(value)
        for reference in refs(schema):
            self.assertIn(reference.removeprefix('#/components/schemas/'), components, reference)


@unittest.skipUnless(HAS_MCP, 'Install the mcp extra')
class NeuronMCP(unittest.IsolatedAsyncioTestCase):
    async def test_check_start_and_read(self):
        from dyno.mcp import create_server
        with tempfile.TemporaryDirectory() as root:
            server, jobs, submissions, stop = lab_server(root)
            try:
                bridge = create_server(server.server_port)

                async def call(name, arguments=None):
                    result = await bridge.call_tool(name, arguments or {})
                    content = result[0] if isinstance(result, tuple) else result
                    return json.loads(content[0].text)
                checked = await call('check_neuron_job', {'operation': 'capture', 'model': 'm', 'settings': {'layers': [14]}})
                self.assertTrue(checked['ok'])
                self.assertEqual((checked['settings']['hook'], checked['settings']['tokens'], checked['settings']['corpus']), ('mlp_hidden', 2_000_000, 'web-mix'))
                self.assertEqual(checked['limit_hours'], 48)
                bad = await call('check_neuron_job', {'operation': 'capture', 'model': 'm', 'settings': {'layers': list(range(9))}})
                self.assertFalse(bad['ok'])
                atlas = await call('check_neuron_job', {'operation': 'atlas', 'settings': {'capture': CAPTURE}})
                self.assertEqual(atlas['settings']['model'], 'mlx-community/Qwen3-0.6B-8bit')
                interp = await call('check_neuron_job', {'operation': 'autointerp', 'settings': {'atlas': ATLAS, 'explainer': {'port': 8083}, 'scorer': {'port': 8084}}})
                self.assertEqual(interp['settings']['units'], {'neuron': 100, 'random': 20})
                self.assertEqual(submissions, [])  # checking never submits
                started = await call('start_neuron_job', {'operation': 'units', 'model': 'm', 'settings': {
                    'mode': 'ablate_set', 'prompt': 'It is', 'target_token': ' Santa', 'units': [[14, 3]]}})
                self.assertEqual(started['status'], 'queued')
                self.assertEqual(submissions[0]['mode'], 'ablate_set')
                index = await call('neuron_atlas_index', {'job_id': ATLAS, 'layer': 14, 'kind': 'neuron', 'sort': 'positive', 'limit': 1})
                self.assertEqual((index['total'], [u['unit'] for u in index['units']]), (2, [1]))
                unit = await call('neuron_atlas_unit', {'job_id': ATLAS, 'layer': 14, 'unit': 0})
                self.assertEqual(unit['poles']['positive']['top'][0], dict(value=4.0, fraction=1.0, token=' cat', text='The cat sat'))
                self.assertEqual(unit['poles']['negative']['top'][0]['token'], ' Santa')
                rows = await call('autointerp_results', {'job_id': AUTOINTERP, 'kind': 'neuron'})
                self.assertEqual((rows['total'], rows['summary']['summary']['neuron']['detection']['pass_rate']), (2, 0.5))
                self.assertNotIn('templates', rows['summary'])
            finally:
                stop()


if __name__ == '__main__':
    unittest.main()
