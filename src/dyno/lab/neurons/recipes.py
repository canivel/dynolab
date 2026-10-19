"""Recipes: a chain of Lab jobs run one after another, each step able to use the jobs before it, ending in one report.

The built-in recipes test claims from Nick Cammarata's "Neural Networks Are Already Clean"
(https://already-clean.goodfire.com/) on a small model:

- `already-clean-fast`: one layer, 2M tokens. Auto-interp with the improved method (both poles, 40 examples, samples
  across the activation range, 1,024-token contexts) and the 2023-style method (positive pole, 20 examples, 64-token
  contexts) on the same neurons, random-direction and shuffled-label baselines, the weak-75 / strong-7 ablation with
  random controls, and an agent interpreter against the one-shot explainer.
- `already-clean-full`: three layers (early, middle, late), 20M tokens, plus a TopK SAE on the middle layer with its
  neuron alignment and auto-interp of its features.

Thresholds are fixed in the recipe, before any run. The report keeps every step's summary and provenance: model and
revision, hooks, corpus commits, seeds, prompt templates and thresholds.
"""
from __future__ import annotations

import copy
import json
import re
import threading
import time
import uuid
from pathlib import Path

REF = re.compile(r'^\$\{(\w[\w-]*)\}$')


def already_clean(full=False):
    layers = [4, 14, 24] if full else [14]
    tokens = 20_000_000 if full else 2_000_000
    neurons = 300 if full else 100
    improved = dict(poles='both', examples=40, stratified=True, window=32, threshold=0.75)
    old_style = dict(poles='positive', examples=20, stratified=False, window=32, threshold=0.75)
    steps = []
    for layer in layers:
        steps += [
            dict(name=f'capture-L{layer}', config=dict(operation='capture', hook='mlp_hidden', layers=[layer], corpus='web-mix', tokens=tokens, context=1024,
                                                     units={'neurons': 'all', 'random_directions': 100})),
            dict(name=f'atlas-L{layer}', config=dict(operation='atlas', capture=f'${{capture-L{layer}}}')),
            dict(name=f'autointerp-L{layer}', config=dict(operation='autointerp', atlas=f'${{atlas-L{layer}}}', layer=layer,
                                                        units={'neuron': neurons, 'random': 40}, condition='improved', **improved)),
            dict(name=f'capture-short-L{layer}', config=dict(operation='capture', hook='mlp_hidden', layers=[layer], corpus='web-mix', tokens=tokens, context=64,
                                                           units={'neurons': 'all', 'random_directions': 100})),
            dict(name=f'atlas-short-L{layer}', config=dict(operation='atlas', capture=f'${{capture-short-L{layer}}}')),
            dict(name=f'autointerp-2023-L{layer}', config=dict(operation='autointerp', atlas=f'${{atlas-short-L{layer}}}', layer=layer,
                                                             units={'neuron': neurons, 'random': 40}, condition='2023-style',
                                                             compare_to=f'${{autointerp-L{layer}}}', **old_style)),
        ]
    middle = layers[len(layers) // 2]
    steps += [
        dict(name='agent', config=dict(operation='autointerp', atlas=f'${{atlas-L{middle}}}', layer=middle, units={'neuron': 20 if not full else 100},
                                       condition='agent', explainer_mode='agent', compare_to=f'${{autointerp-L{middle}}}', **improved)),
        dict(name='ablate', config=dict(operation='ablate', hook='mlp_hidden', layers='all', corpus='web-mix', eval_tokens=100_000 if not full else 500_000)),
    ]
    if full:
        steps += [
            dict(name='sae', config=dict(operation='sae_train', hook='mlp_hidden', layers=[middle], corpus='web-mix', tokens=tokens, architecture='topk',
                                         expansion=4, k=32, seeds=[0, 1, 2])),
            dict(name='capture-sae', config=dict(operation='capture', hook='mlp_hidden', layers=[middle], corpus='web-mix', tokens=tokens // 4, context=1024,
                                                 units={'neurons': None, 'sae': '${sae}'})),
            dict(name='atlas-sae', config=dict(operation='atlas', capture='${capture-sae}')),
            dict(name='autointerp-sae', config=dict(operation='autointerp', atlas='${atlas-sae}', layer=middle, units={'sae': 300}, condition='sae', **improved)),
        ]
    return dict(title='Neural networks are already clean' + (' (full)' if full else ' (fast pass)'),
                description='Neuron poles labeled and scored with the improved and 2023-style methods, random-direction and shuffled-label baselines, '
                            'weak vs strong activation ablation, and an agent interpreter' + (', plus SAE alignment' if full else '') + '.',
                credit='Nick Cammarata, "Neural Networks Are Already Clean" (Goodfire): https://already-clean.goodfire.com/',
                hypotheses=[
                    'H1: with the improved method, at least half of neuron poles at the middle layer pass detection >= 0.75 (falsified below 50%).',
                    'H2: the improved method passes at least 15 points more poles than the 2023-style method (paired, p < 0.01).',
                    'H4: weak-75 changes the top prediction less than its mass-matched random control; strong-7 changes it more than weak-75.',
                    'H6: the agent interpreter beats the one-shot explainer by at least 5 points of detection (paired, p < 0.05).',
                ] + (['H3: candidate new building blocks are under 30% of interpretable SAE features.'] if full else []),
                steps=steps)


BUILTIN = {'already-clean-fast': lambda: already_clean(False), 'already-clean-full': lambda: already_clean(True)}


def resolve(value, ids):
    """Replace ${step} references with the job ids of finished steps."""
    if isinstance(value, str):
        m = REF.match(value)
        if m:
            if m.group(1) not in ids: raise ValueError(f'Step reference {value} comes before that step')
            return ids[m.group(1)]
        return value
    if isinstance(value, list): return [resolve(v, ids) for v in value]
    if isinstance(value, dict): return {k: resolve(v, ids) for k, v in value.items()}
    return value


def instantiate(body):
    """The recipe to run: a built-in or a custom one, with the model and scoring models filled into each step."""
    if not isinstance(body, dict): raise ValueError('A recipe run is a JSON object')
    name = body.get('recipe')
    recipe = BUILTIN[name]() if name in BUILTIN else body.get('custom')
    if not isinstance(recipe, dict) or not isinstance(recipe.get('steps'), list) or not recipe['steps']:
        raise ValueError(f'recipe: one of {", ".join(BUILTIN)}, or custom: {{"title", "steps": [{{"name", "config"}}]}}')
    if not isinstance(body.get('model'), str) or not body['model'].strip(): raise ValueError('model: the model to study')
    recipe = copy.deepcopy(recipe)
    names = set()
    for step in recipe['steps']:
        if not isinstance(step, dict) or not isinstance(step.get('name'), str) or not isinstance(step.get('config'), dict): raise ValueError('Each step has a name and a config')
        if step['name'] in names: raise ValueError(f'Step names must be unique: {step["name"]}')
        names.add(step['name'])
        config = step['config']
        if config.get('operation') != 'autointerp': config.setdefault('model', body['model'])
        if body.get('revision'): config.setdefault('revision', body['revision'])
        if config.get('operation') == 'autointerp':
            for key in ('explainer', 'scorer'):
                if key not in config:
                    if not body.get(key): raise ValueError(f'{key}: {{"port"}} of a local model server, for the auto-interp steps')
                    config[key] = body[key]
        if body.get('seed') is not None: config.setdefault('seed', body['seed'])
    if body.get('only'):
        recipe['steps'] = [s for s in recipe['steps'] if s['name'] in set(body['only'])]
    return recipe


class Recipes:
    """Runs one recipe at a time, step by step, through the Lab's job queue."""

    def __init__(self, root, jobs):
        self.root = Path(root) / 'recipes'
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.jobs, self.lock, self.active, self.cancelled = jobs, threading.RLock(), None, threading.Event()
        for path in self.root.glob('*.json'):
            try:
                data = json.loads(path.read_text())
                if data.get('status') == 'running':
                    data.update(status='interrupted'); self._write(data)
            except (OSError, ValueError):
                pass

    def _write(self, data):
        path = self.root / f"{data['id']}.json"
        tmp = path.with_suffix('.tmp'); tmp.write_text(json.dumps(data, indent=2)); tmp.replace(path)

    def builtins(self):
        return {name: dict((f := make()), steps=[dict(name=s['name'], operation=s['config']['operation']) for s in f['steps']]) for name, make in BUILTIN.items()}

    def list(self):
        out = []
        for path in self.root.glob('*.json'):
            try: out.append({k: v for k, v in json.loads(path.read_text()).items() if k not in ('recipe', 'report')})
            except (OSError, ValueError): pass
        return sorted(out, key=lambda d: d['created'], reverse=True)

    def read(self, identifier):
        if not re.fullmatch(r'[0-9a-f]{32}', identifier or ''): raise FileNotFoundError(identifier)
        return json.loads((self.root / f'{identifier}.json').read_text())

    def start(self, body):
        recipe = instantiate(body)
        # Check every step's settings now (references are checked as they resolve).
        from ..server import validate
        earlier = {}
        for step in recipe['steps']:
            validate(resolve(step['config'], earlier))  # a step may use only the steps before it
            earlier[step['name']] = '0' * 32
        with self.lock:
            if self.active: raise RuntimeError('A recipe is already running')
            data = dict(id=uuid.uuid4().hex, created=time.time(), status='running', title=recipe['title'], model=body['model'],
                        recipe=recipe, steps=[dict(name=s['name'], operation=s['config']['operation'], status='waiting') for s in recipe['steps']])
            self._write(data)
            self.active = data['id']
            self.cancelled.clear()
            threading.Thread(target=self._run, args=(data,), daemon=True).start()
            return data

    def cancel(self, identifier):
        with self.lock:
            data = self.read(identifier)
            if self.active == identifier:
                self.cancelled.set()
                if self.jobs.active: self.jobs.cancel(self.jobs.active)
            return data

    def _run(self, data):
        ids = {}
        try:
            for n, step in enumerate(data['recipe']['steps']):
                if self.cancelled.is_set(): raise RuntimeError('Cancelled')
                config = resolve(step['config'], ids)
                while self.jobs.active:  # another job is running: wait for the queue
                    if self.cancelled.is_set(): raise RuntimeError('Cancelled')
                    time.sleep(2)
                job = self.jobs.submit(config)
                data['steps'][n].update(status='running', job=job['id'], started=time.time()); self._write(data)
                while True:
                    time.sleep(2)
                    current = self.jobs.read(job['id'])
                    if current['status'] not in ('queued', 'running'): break
                data['steps'][n].update(status=current['status'], ended=time.time())
                if current['status'] != 'completed':
                    data['steps'][n]['error'] = (current.get('error') or '')[-2000:]
                    raise RuntimeError(f"Step {step['name']} {current['status']}")
                ids[step['name']] = job['id']
                self._write(data)
            data['report'] = self.report(data, ids)
            data['status'] = 'completed'
        except Exception as error:  # noqa: BLE001 - the recipe records why it stopped
            data.update(status='cancelled' if self.cancelled.is_set() else 'failed', error=str(error)[-2000:])
        finally:
            data['ended'] = time.time()
            self._write(data)
            with self.lock:
                if self.active == data['id']: self.active = None

    def report(self, data, ids):
        """Every step's summary and provenance, and the recipe's hypotheses next to the numbers that test them."""
        steps = {}
        for step in data['recipe']['steps']:
            job = self.jobs.read(ids[step['name']])
            result = job.get('result') or {}
            summary = {k: v for k, v in result.items() if k in ('capture', 'atlas', 'reports', 'ablation', 'autointerp', 'attribution', 'ablate_set', 'steer', 'warnings')}
            if 'autointerp' in summary: summary['autointerp'] = {k: v for k, v in summary['autointerp'].items() if k != 'templates'}
            steps[step['name']] = dict(job=job['id'], operation=step['config']['operation'], config={k: v for k, v in job['config'].items() if k != 'examples'},
                                       summary=summary, provenance=result.get('provenance'), hook=result.get('hook'))
        templates = next((self.jobs.read(ids[s['name']]).get('result', {}).get('autointerp', {}).get('templates')
                          for s in data['recipe']['steps'] if s['config']['operation'] == 'autointerp'), None)
        return dict(format='dynolab-neurons', version=1, title=data['recipe']['title'], description=data['recipe'].get('description'),
                    credit=data['recipe'].get('credit'), hypotheses=data['recipe'].get('hypotheses'), model=data['model'],
                    created=time.time(), steps=steps, prompt_templates=templates)
