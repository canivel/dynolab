"""Inspect AI evals in Dyno: build, import and run evals and benchmarks on the models running on this Mac.

Inspect AI (the UK AI Security Institute's open-source evaluation framework, MIT) does the work: a task is a
dataset of samples, a solver (how the model is asked) and a scorer (how answers are marked). Dyno saves the
eval definitions, runs each one with Inspect in a separate worker process against a local model server
(Inspect's `openai-api` provider), reads the results from Inspect's own logs and opens them in Inspect View.

Three kinds of eval:
- `dataset`: samples you write or import (CSV, JSONL or JSON with input and target).
- `task_file`: an Inspect task written in Python (`@task`). It is code: it runs only when you start it.
- `library`: a benchmark from the inspect_evals package (installed on demand; it downloads its dataset).
"""
from __future__ import annotations

import csv
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from .evals import wilson

_ID = re.compile(r'^[0-9a-f]{32}$')
SOLVERS = ('generate', 'chain_of_thought', 'multiple_choice')
SCORERS = ('includes', 'match', 'exact', 'pattern', 'choice', 'model_graded_qa', 'model_graded_fact')
MAX_SAMPLES = 2000

# inspect_evals benchmarks that run on a local model without Docker. `judge` means a second model marks the
# answers (Dyno passes the judge you pick as Inspect's "grader" role); `download` means the first run fetches
# the dataset from Hugging Face.
LIBRARY = [
    dict(id='inspect_evals/sad_stages_oversight', task='sad_stages_oversight', headline=dict(metric='accuracy', label='Told eval from deployment', better='higher'), title='SAD: stages (oversight)', area='Evaluation awareness',
         what='Can the model tell evaluation prompts from real deployment? From the Situational Awareness Dataset.',
         samples=400, judge=False, judge_args=[], gated=False),
    dict(id='inspect_evals/strong_reject', task='strong_reject', headline=dict(metric='strong_reject_metric', label='StrongREJECT score', better='lower'), title='StrongREJECT', area='Harmful compliance',
         what='313 forbidden requests; a judge rates how useful the answer would be to someone misusing it.',
         samples=313, judge=True, judge_args=['judge_llm'], gated=False),
    dict(id='inspect_evals/agentic_misalignment', task='agentic_misalignment', headline=dict(metric='harmful', label='Harmful actions', better='lower'), title='Agentic Misalignment', area='Misalignment',
         what='An agent can blackmail or leak to keep its goal; a judge marks harmful actions. Includes an eval-awareness variant.',
         samples=1, judge=True, judge_args=['grader_model'], gated=False),
    dict(id='inspect_evals/mask', task='mask', headline=dict(metric='honesty', label='Honesty', better='higher'), title='MASK', area='Honesty',
         what='Does the model state what it believes when pressured to say otherwise? A judge compares its belief and its statement.',
         samples=1000, judge=True, judge_args=['binary_judge_model', 'numeric_judge_model'], gated=False),
    dict(id='inspect_evals/truthfulqa', task='truthfulqa', headline=dict(metric='accuracy', label='Truthful answers', better='higher'), title='TruthfulQA', area='Honesty',
         what='817 questions where a popular misconception is the tempting answer (multiple choice).',
         samples=817, judge=False, judge_args=[], gated=False),
    dict(id='inspect_evals/simpleqa', task='simpleqa', headline=dict(metric='correct', label='Correct', better='higher'), title='SimpleQA', area='Factuality',
         what='Short fact questions; a judge marks each answer correct, incorrect or not attempted.',
         samples=4326, judge=True, judge_args=[], gated=False),
    dict(id='inspect_evals/wmdp_bio', task='wmdp_bio', headline=dict(metric='accuracy', label='Hazardous-knowledge accuracy', better='neutral'), title='WMDP (biology)', area='Hazardous knowledge',
         what='Multiple-choice questions that proxy dangerous biosecurity knowledge.',
         samples=1273, judge=False, judge_args=[], gated=False),
    dict(id='inspect_evals/bbq', task='bbq', headline=dict(metric='accuracy', label='Unbiased answers', better='higher'), title='BBQ', area='Bias',
         what='Questions that test whether social stereotypes change the answer (multiple choice).',
         samples=58492, judge=False, judge_args=[], gated=False),
    dict(id='inspect_evals/xstest', task='xstest', headline=dict(metric='refusal_rate', label='Refusal rate', better='neutral'), title='XSTest', area='Over-refusal',
         what='250 safe prompts that look unsafe, and 200 unsafe ones: does the model refuse the right ones?',
         samples=450, judge=True, judge_args=['scorer_model'], gated=True,
         hf='https://huggingface.co/datasets/walledai/XSTest'),
]


def _load(path):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return {}


def _save(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp'); tmp.write_text(json.dumps(value, indent=2)); tmp.replace(path)


def _text(value, name, limit=20_000, required=False):
    if value is None: value = ''
    if not isinstance(value, str): raise ValueError(f'{name} must be text')
    value = value.strip()
    if required and not value: raise ValueError(f'{name} is required')
    if len(value) > limit: raise ValueError(f'{name} is too long')
    return value


def available():
    """Whether Inspect AI and the OpenAI client it uses for local servers are installed."""
    ok = all(importlib.util.find_spec(m) is not None for m in ('inspect_ai', 'openai'))
    version = None
    if ok:
        try:
            from importlib.metadata import version as v
            version = v('inspect-ai')
        except Exception: pass
    return ok, version


# --- importing ------------------------------------------------------------------------------

_ALIASES = {'input': ('input', 'question', 'prompt'), 'target': ('target', 'answer', 'expected', 'ideal'), 'id': ('id',)}


def _sample(row, i):
    if not isinstance(row, dict): raise ValueError(f'Row {i}: expected an object with input and target')
    pick = lambda key: next((row[k] for k in _ALIASES[key] if row.get(k) not in (None, '')), None)
    inp = pick('input')
    if inp is None: raise ValueError(f'Row {i}: no input (or question / prompt)')
    target = pick('target')
    s = dict(input=str(inp)[:20_000], target=[str(t)[:4000] for t in target] if isinstance(target, list) else str(target or '')[:4000])
    if pick('id') is not None: s['id'] = str(pick('id'))[:100]
    if isinstance(row.get('choices'), list): s['choices'] = [str(c)[:2000] for c in row['choices'][:26]]
    elif isinstance(row.get('choices'), str) and row['choices'].strip():
        s['choices'] = [c.strip() for c in row['choices'].split('|') if c.strip()][:26]
    meta = {k: v for k, v in row.items() if k not in {a for al in _ALIASES.values() for a in al} | {'choices'}}
    if meta: s['metadata'] = {str(k)[:60]: (v if isinstance(v, (int, float, bool)) else str(v)[:500]) for k, v in list(meta.items())[:20]}
    return s


def parse_import(body):
    """A draft eval from pasted or opened text: CSV/JSONL/JSON samples, or an Inspect task file. Nothing is saved."""
    text = body.get('text')
    if not isinstance(text, str) or not text.strip(): raise ValueError('Open a file or paste its contents')
    if len(text) > 5_000_000: raise ValueError('The file is too large (5 MB at most)')
    name = _text(body.get('name'), 'name', 200) or 'Imported eval'
    stem = re.sub(r'\.(csv|jsonl|json|py)$', '', name, flags=re.I)
    kind = (body.get('format') or '').lower() or ('py' if name.endswith('.py') else 'csv' if name.lower().endswith('.csv') else
                                                 'jsonl' if name.lower().endswith('.jsonl') else 'json' if name.lower().endswith('.json') else '')
    warnings = []
    if kind == 'py' or ('@task' in text and 'def ' in text):
        tasks = re.findall(r'@task(?:\([^)]*\))?\s*\n\s*def\s+([A-Za-z_][A-Za-z0-9_]*)', text)
        if not tasks: raise ValueError('No @task function found in this Python file')
        return dict(draft=dict(kind='task_file', title=stem, description='', task_file=dict(name=name if name.endswith('.py') else name + '.py',
                    code=text, task=tasks[0]), tasks=tasks, epochs=1),
                    warnings=['This is Python code. It runs on your Mac with your permissions when you start the eval. Read it first.'])
    rows = []
    if kind == 'csv' or (not kind and ',' in text.splitlines()[0] and not text.lstrip().startswith(('{', '['))):
        rows = list(csv.DictReader(io.StringIO(text)))
    elif kind == 'jsonl' or (not kind and text.lstrip().startswith('{') and '\n{' in text):
        for i, line in enumerate(text.splitlines(), 1):
            if line.strip():
                try: rows.append(json.loads(line))
                except ValueError: raise ValueError(f'Line {i} is not valid JSON')
    else:
        try: data = json.loads(text)
        except ValueError: raise ValueError('Not CSV, JSONL, JSON or an Inspect task file')
        rows = data if isinstance(data, list) else data.get('samples') or data.get('dataset') or []
    if not rows: raise ValueError('No samples found')
    samples = [_sample(r, i) for i, r in enumerate(rows[:MAX_SAMPLES], 1)]
    if len(rows) > MAX_SAMPLES: warnings.append(f'Only the first {MAX_SAMPLES} of {len(rows)} samples were kept')
    if not any(s.get('target') for s in samples): warnings.append('No targets: pick a judge-based scorer, or add targets')
    scorer = 'choice' if all(s.get('choices') for s in samples) else 'includes'
    solver = 'multiple_choice' if scorer == 'choice' else 'generate'
    return dict(draft=dict(kind='dataset', title=stem, description='', dataset=samples, solver=dict(kind=solver, system_prompt=''),
                           scorer=dict(kind=scorer, ignore_case=True), epochs=1), warnings=warnings)


def headline(metrics, lib, passed, total):
    """The number to show for a run: the benchmark's own headline metric and which way is better, else the share
    of samples marked correct."""
    want = ((lib or {}).get('headline') or {})
    key = next((k for k in metrics if want.get('metric') and k.split('/')[-1] == want['metric']), None)
    if key is None and passed is None:
        key = next((k for k in metrics if k.endswith('/accuracy')), None) or next((k for k in metrics if not k.endswith('/stderr')), None)
    if key is not None and isinstance(metrics.get(key), (int, float)):
        return dict(key=key, label=want.get('label') or key.split('/')[-1].replace('_', ' ').capitalize(), value=metrics[key],
                    better=want.get('better') or 'higher')
    if passed is not None and total:
        return dict(key='correct', label='Correct', value=passed / total, better='higher')
    return None


# --- the store, runs and the viewer ---------------------------------------------------------

class InspectEvals:
    def __init__(self, evals):
        self.evals = evals
        self.folder = evals.folder / 'inspect'
        for sub in ('defs', 'runs'): (self.folder / sub).mkdir(parents=True, exist_ok=True, mode=0o700)
        self.extras = evals.runs.root.parent / 'inspect-extras'  # inspect_evals, installed on demand
        self.lock = threading.RLock()
        self.thread = None
        self.procs = {}
        self.tokens = {}  # run id → Hugging Face token, in memory only
        self.viewer = None
        self.install = dict(running=False, error=None)
        for path in (self.folder / 'runs').glob('*/run.json'):
            r = _load(path)
            if r.get('status') == 'running':
                r.update(status='interrupted', ended=time.time()); _save(path, r)

    # definitions
    def _def_path(self, i):
        if not _ID.match(i or ''): raise ValueError('Unknown eval')
        return self.folder / 'defs' / f'{i}.json'

    def get_def(self, i):
        d = _load(self._def_path(i))
        if not d: raise ValueError('Unknown eval')
        return d

    def defs(self):
        out = []
        for p in sorted((self.folder / 'defs').glob('*.json')):
            d = _load(p)
            if d: out.append({k: d.get(k) for k in ('id', 'title', 'description', 'kind', 'epochs', 'updated', 'created')} |
                             dict(samples=len(d.get('dataset') or []) if d.get('kind') == 'dataset' else None,
                                  library=(d.get('library') or {}).get('id'), scorer=(d.get('scorer') or {}).get('kind')))
        return sorted(out, key=lambda d: -(d.get('updated') or 0))

    def save_def(self, body):
        if not isinstance(body, dict): raise ValueError('Send an eval')
        kind = body.get('kind')
        if kind not in ('dataset', 'task_file', 'library'): raise ValueError('kind must be dataset, task_file or library')
        now = time.time()
        old = _load(self._def_path(body['id'])) if body.get('id') else {}
        d = dict(id=old.get('id') or uuid.uuid4().hex, kind=kind, title=_text(body.get('title'), 'title', 160, True),
                 description=_text(body.get('description'), 'description', 4000), created=old.get('created') or now, updated=now)
        epochs = body.get('epochs', 1)
        if not isinstance(epochs, int) or not 1 <= epochs <= 20: raise ValueError('epochs must be 1–20')
        d['epochs'] = epochs
        if kind == 'dataset':
            rows = body.get('dataset')
            if not isinstance(rows, list) or not rows: raise ValueError('Add at least one sample')
            d['dataset'] = [_sample(r, i) for i, r in enumerate(rows[:MAX_SAMPLES], 1)]
            solver = body.get('solver') or {}
            if solver.get('kind', 'generate') not in SOLVERS: raise ValueError(f'solver must be one of {", ".join(SOLVERS)}')
            d['solver'] = dict(kind=solver.get('kind', 'generate'), system_prompt=_text(solver.get('system_prompt'), 'system prompt', 20_000))
        if kind in ('dataset', 'library'):
            scorer = body.get('scorer') or {}
            if kind == 'dataset':
                if scorer.get('kind', 'includes') not in SCORERS: raise ValueError(f'scorer must be one of {", ".join(SCORERS)}')
                d['scorer'] = dict(kind=scorer.get('kind', 'includes'), ignore_case=bool(scorer.get('ignore_case', True)),
                                   pattern=_text(scorer.get('pattern'), 'pattern', 500), instructions=_text(scorer.get('instructions'), 'instructions', 8000))
                if d['scorer']['kind'] == 'pattern':
                    try: re.compile(d['scorer']['pattern'])
                    except re.error: raise ValueError('The pattern is not a valid regular expression')
        if kind == 'task_file':
            tf = body.get('task_file') or {}
            code = tf.get('code')
            if not isinstance(code, str) or '@task' not in code: raise ValueError('The task file needs an @task function')
            name = re.sub(r'[^A-Za-z0-9_.-]', '_', str(tf.get('name') or 'task.py'))[:80]
            d['task_file'] = dict(name=name if name.endswith('.py') else name + '.py', code=code[:500_000],
                                  task=_text(tf.get('task'), 'task', 100, True))
        if kind == 'library':
            lib = body.get('library') or {}
            if lib.get('id') not in {x['id'] for x in LIBRARY}: raise ValueError('Unknown benchmark')
            d['library'] = dict(id=lib['id'], limit=lib.get('limit') if isinstance(lib.get('limit'), int) and lib['limit'] > 0 else None)
        _save(self._def_path(d['id']), d)
        return d

    def delete_def(self, i):
        p = self._def_path(i)
        if p.exists(): p.unlink()
        return dict(deleted=i)

    # library
    def library(self):
        installed = (self.extras / 'inspect_evals').is_dir() or importlib.util.find_spec('inspect_evals') is not None
        return dict(installed=installed, install=self.install, items=LIBRARY)

    def install_library(self):
        with self.lock:
            if self.install.get('running'): return self.library()
            self.install = dict(running=True, error=None, started=time.time())
        def work():
            try:
                self.extras.mkdir(parents=True, exist_ok=True)
                from importlib.metadata import version
                # Pinned to the bundled Inspect AI and openai, so pip resolves a consistent set around the same versions.
                cmd = [sys.executable, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', '--target', str(self.extras),
                       'inspect-evals', f"inspect-ai=={version('inspect-ai')}", f"openai=={version('openai')}"]
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
                err = None if p.returncode == 0 else (p.stderr or p.stdout)[-800:]
            except Exception as e: err = str(e)[-800:]
            self.install = dict(running=False, error=err, ended=time.time())
        threading.Thread(target=work, daemon=True).start()
        return self.library()

    # runs
    def status(self):
        ok, version = available()
        return dict(available=ok, version=version, defs=self.defs(), runs=self.runs()[:50],
                    library_installed=self.library()['installed'], viewer=self.viewer_url())

    def _run_path(self, i):
        if not _ID.match(i or ''): raise ValueError('Unknown run')
        return self.folder / 'runs' / i / 'run.json'

    def runs(self):
        out = [_load(p) for p in (self.folder / 'runs').glob('*/run.json')]
        return sorted([self._summary(r) for r in out if r], key=lambda r: -(r.get('created') or 0))

    def _summary(self, r):
        return {k: r.get(k) for k in ('id', 'def_id', 'title', 'kind', 'status', 'created', 'ended', 'error')} | dict(
            models=[{k: m.get(k) for k in ('label', 'model', 'port', 'status', 'done', 'total', 'accuracy', 'pass', 'n', 'ci', 'error')} for m in r.get('models') or []])

    def run(self, i):
        r = _load(self._run_path(i))
        if not r: raise ValueError('Unknown run')
        return r

    def start_run(self, body):
        ok, _ = available()
        if not ok: raise ValueError('Inspect AI is not installed in this Dyno runtime')
        d = self.get_def(body.get('def') or body.get('eval') or '')
        models = body.get('models') or []
        if not isinstance(models, list) or not models: raise ValueError('Choose at least one running model')
        clean = []
        for m in models[:8]:
            port, name = m.get('port'), m.get('model')
            if not isinstance(port, int) or not 1024 <= port <= 65535 or not isinstance(name, str) or not name:
                raise ValueError('Each model needs a port and a name')
            clean.append(dict(port=port, model=name[:300], label=str(m.get('label') or name.split('/')[-1])[:120], status='queued', done=0, total=None))
        grader = body.get('grader')
        if grader is not None and (not isinstance(grader.get('port'), int) or not grader.get('model')): raise ValueError('The judge needs a port and a model')
        needs_judge = (d.get('scorer') or {}).get('kind', '').startswith('model_graded') or next((x['judge'] for x in LIBRARY if x['id'] == (d.get('library') or {}).get('id')), False)
        if needs_judge and not grader: raise ValueError('This eval is marked by a judge model: choose one')
        if d['kind'] == 'library' and not self.library()['installed']: raise ValueError('Install the benchmark library first')
        with self.lock:
            if self.thread and self.thread.is_alive(): raise ValueError('An Inspect run is in progress; wait for it or cancel it')
            epochs = body.get('epochs') if isinstance(body.get('epochs'), int) and 1 <= body['epochs'] <= 20 else d.get('epochs', 1)
            r = dict(id=uuid.uuid4().hex, def_id=d['id'], title=d['title'], kind=d['kind'], created=time.time(), status='running',
                     epochs=epochs, limit=body.get('limit') if isinstance(body.get('limit'), int) and body['limit'] > 0 else None,
                     grader=grader, models=clean, definition=d)
            _save(self._run_path(r['id']), r)
            if isinstance(body.get('hf_token'), str) and body['hf_token'].strip(): self.tokens[r['id']] = body['hf_token'].strip()[:200]
            self.thread = threading.Thread(target=self._loop, args=(r['id'],), daemon=True)
            self.thread.start()
        return self._summary(r)

    def cancel_run(self, i):
        r = self.run(i)
        with self.lock:
            r['status'] = 'cancelled'; r['ended'] = time.time(); _save(self._run_path(i), r)
            p = self.procs.get(i)
        if p and p.poll() is None: p.terminate()
        return self._summary(r)

    def _loop(self, i):
        try: self._run_models(i)
        except Exception as error:  # never leave a run stuck as "running"
            r = self.run(i); r.update(status='error', error=f'{type(error).__name__}: {error}'[:1000], ended=time.time()); _save(self._run_path(i), r)

    def _run_models(self, i):
        folder = self._run_path(i).parent
        r = self.run(i)
        for n, m in enumerate(r['models']):
            if self.run(i).get('status') == 'cancelled': break
            lib = next((x for x in LIBRARY if x['id'] == (r['definition'].get('library') or {}).get('id')), None)
            job = dict(definition=r['definition'], model=m, grader=r.get('grader'), epochs=r['epochs'], limit=r.get('limit') or (r['definition'].get('library') or {}).get('limit'),
                       library=lib,
                       log_dir=str(folder / 'logs'), progress=str(folder / f'progress-{n}.jsonl'), result=str(folder / f'result-{n}.json'),
                       workdir=str(folder), extras=str(self.extras))
            (folder / f'job-{n}.json').write_text(json.dumps(job))
            self._update(i, n, status='running', started=time.time())
            env = dict(os.environ, DYNO_API_KEY='local', INSPECT_LOG_DIR=str(folder / 'logs'), PYTHONDONTWRITEBYTECODE='1',
                       PYTHONPATH=os.pathsep.join([str(self.extras), *sys.path]), INSPECT_DISPLAY='none', NO_COLOR='1',
                       HF_HUB_DISABLE_TELEMETRY='1')  # the library's consistent set first; same Inspect and openai versions
            token = self.tokens.get(i)
            if token: env['HF_TOKEN'] = token  # for gated datasets; never written to disk
            with open(folder / f'worker-{n}.log', 'w') as log:
                p = subprocess.Popen([sys.executable, '-m', 'dyno.lab.inspect_worker', str(folder / f'job-{n}.json')], env=env,
                                     stdout=log, stderr=subprocess.STDOUT, cwd=str(folder))
                with self.lock: self.procs[i] = p
                while p.poll() is None:
                    self._update(i, n, **self._progress(folder, n))
                    time.sleep(1)
            res = _load(folder / f'result-{n}.json')
            if res.get('status') == 'success':
                passed, total = res.get('pass'), res.get('n', 0)  # pass is None when scores aren't right/wrong
                self._update(i, n, status='done', done=total, total=total, accuracy=res.get('accuracy'), metrics=res.get('metrics'),
                             **{'pass': passed}, n=total, ci=wilson(passed, total) if passed is not None else None,
                             headline=headline(res.get('metrics') or {}, lib, passed, total), samples=res.get('samples'), log=res.get('log'))
            else:
                tail = (folder / f'worker-{n}.log').read_text(errors='replace')[-1500:] if (folder / f'worker-{n}.log').exists() else ''
                self._update(i, n, status='error', error=res.get('error') or tail or f'worker exited with {p.returncode}', log=res.get('log'))
        self.tokens.pop(i, None)
        r = self.run(i)
        if r.get('status') == 'running':
            r['status'] = 'done' if all(m['status'] == 'done' for m in r['models']) else 'error' if all(m['status'] == 'error' for m in r['models']) else 'partial'
            r['ended'] = time.time(); _save(self._run_path(i), r)

    def _progress(self, folder, n):
        done = total = 0
        try:
            for line in (folder / f'progress-{n}.jsonl').read_text().splitlines():
                e = json.loads(line)
                if e.get('event') == 'start': total = e.get('total') or total
                if e.get('event') == 'sample': done += 1
        except (OSError, ValueError): pass
        return dict(done=done, total=total or None)

    def _update(self, i, idx, **fields):
        with self.lock:
            r = self.run(i); r['models'][idx].update(fields); _save(self._run_path(i), r)

    # Evals overview: one row per eval, one column per model
    def results(self):
        cells = {}
        for p in (self.folder / 'runs').glob('*/run.json'):
            r = _load(p)
            for m in r.get('models') or []:
                if m.get('status') != 'done' or not m.get('n'): continue
                c = cells.setdefault((r['def_id'], m['label']), dict(def_id=r['def_id'], title=r.get('title'), kind=r.get('kind'),
                                                                     label=m['label'], model=m.get('model'), pass_=0, n=0, runs=0, last=0))
                if m.get('pass') is None: c['graded'] = False
                c['pass_'] += m.get('pass') or 0; c['n'] += m['n']; c['runs'] += 1
                if (r.get('created') or 0) > c['last']: c.update(last=r.get('created') or 0, run=r['id'], accuracy=m.get('accuracy'), headline=m.get('headline'))
        out = []
        for c in cells.values():
            passed, graded = c.pop('pass_'), c.pop('graded', True)
            if not graded:  # scores aren't right/wrong: show the benchmark's headline metric instead
                out.append(dict(c, **{'pass': None}, rate=None, ci=None)); continue
            out.append(dict(c, **{'pass': passed}, rate=round(passed / c['n'], 4) if c['n'] else None, ci=wilson(passed, c['n'])))
        return sorted(out, key=lambda c: (c['title'] or '', c['label']))

    # Inspect View: the framework's own log viewer
    def viewer_url(self):
        return 'http://127.0.0.1:7576' if self.viewer and self.viewer.poll() is None else None

    def open_viewer(self, run=None):
        log_dir = (self._run_path(run).parent / 'logs') if run else (self.folder / 'runs')
        with self.lock:
            if self.viewer and self.viewer.poll() is None and getattr(self.viewer, 'log_dir', None) == str(log_dir): return dict(url=self.viewer_url())
            if self.viewer and self.viewer.poll() is None: self.viewer.terminate()
            env = dict(os.environ, PYTHONPATH=os.pathsep.join(sys.path))
            self.viewer = subprocess.Popen([sys.executable, '-m', 'inspect_ai', 'view', 'start', '--log-dir', str(log_dir), '--host', '127.0.0.1', '--port', '7576'],
                                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.viewer.log_dir = str(log_dir)
        for _ in range(40):
            try:
                import urllib.request
                urllib.request.urlopen('http://127.0.0.1:7576', timeout=0.5); break
            except Exception: time.sleep(0.25)
        return dict(url=self.viewer_url())
