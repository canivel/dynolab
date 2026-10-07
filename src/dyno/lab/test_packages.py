"""Shareable test packages: a whole agent test setup in one JSON file.

A package holds the environment (with its files), the goal, the rules (with their detectors and
delivery), the lead agent and limits, the agent prompt, the test's own Observer alerts, and the
GHOST script and history. It never holds a model: the person who imports it chooses one that runs on
their machine (`lead.model_hint` says what the author used).

    {"format": "dynolab-test", "version": 1, "title": ..., "description": ..., "author": ...,
     "environment": {"id", "spec", "files"} | null, "goal": ..., "rules": [...],
     "lead": {"name", "role", "model_hint"}, "limits": {...}, "prompt": {"name", "lead", "teammate"} | null,
     "alerts": [...], "script": [...], "rules_from": ..., "history": [...], "hash": "sha256:..."}

Importing runs nothing. It saves the environment and the prompt (reusing identical ones) and returns a
setup for the Setup screen; the environment only does anything inside the sandbox once a test starts.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import time
import urllib.parse
import urllib.request

FORMAT, VERSION = 'dynolab-test', 1
MAX_BYTES = 2_000_000
LIMIT_KEYS = ('max_rounds', 'max_seconds', 'steps_per_turn', 'max_agents', 'follow_up_seconds')
RULE_KEYS = ('text', 'watch', 'delivery', 'at')


def _canonical(package):
    return json.dumps({k: v for k, v in package.items() if k != 'hash'}, sort_keys=True, ensure_ascii=False, separators=(',', ':'))


def package_hash(package):
    return 'sha256:' + hashlib.sha256(_canonical(package).encode()).hexdigest()


def _same_env(a, b):
    """Two environments are the same when their spec (ignoring the id) and files match."""
    strip = lambda e: json.dumps(dict({k: v for k, v in (e.get('spec') or {}).items() if k != 'id'}), sort_keys=True)
    return strip(a) == strip(b) and (a.get('files') or {}) == (b.get('files') or {})


class TestPackages:
    def __init__(self, runs):
        self.runs = runs

    # --- export ---------------------------------------------------------------------------

    def export(self, body):
        """A package from a setup (`spec`, as the app sends it to start a test) or a past test (`room`)."""
        if not isinstance(body, dict) or set(body) - {'spec', 'room', 'title', 'description', 'author', 'harness_dir'}:
            raise ValueError('Send spec or room, and optionally title, description and author')
        hd = body.get('harness_dir')
        if body.get('room'):
            record = self.runs.read_record(body['room'])
            if record.get('kind') != 'room': raise ValueError('Not a test')
            spec = dict((record.get('config') or {}).get('spec') or {})
            alerts = [a for a in spec.get('alerts') or []]
            # The detectors Dyno chose for rules without one are in the run's own definition.
            folder = next((f.parent for f in sorted((self.runs.root / body['room'] / 'episodes').glob('*/definition/room.json'))), None)
            planned = (json.loads((folder / 'room.json').read_text()).get('rules') or []) if folder else []
            if len(planned) == len(spec.get('rules') or []):
                spec['rules'] = [dict(r, watch=r.get('watch') or q.get('watch')) for r, q in zip(spec['rules'], planned)]
        elif isinstance(body.get('spec'), dict):
            spec = self.runs._room_spec(body['spec'], complete=False)
            alerts = spec.pop('test_alerts', []) + [a for a in self.runs.alerts.list()['alerts'] if a.get('enabled')]
        else:
            raise ValueError('Send the setup (spec) or a past test (room)')
        env = None
        if spec.get('environment'):
            detail = self.runs.environment_detail(hd, spec['environment'])
            env = dict(id=spec['environment'], spec=detail['spec'], files={k: v for k, v in detail['files'].items() if v is not None})
        prompt = None
        if spec.get('prompts'):
            ref = spec.get('prompt_ref') or {}
            prompt = dict(name=ref.get('name') or 'Shared prompt', lead=spec['prompts'].get('lead', ''), teammate=spec['prompts'].get('teammate', ''))
        lead = (spec.get('agents') or [{}])[0]
        portable = []
        for a in alerts:  # alerts travel without machine-specific model settings
            item = {k: a[k] for k in ('id', 'name', 'description', 'severity', 'kind', 'reads', 'phrases', 'regex', 'question') if k in a}
            portable.append(item)
        package = dict(
            format=FORMAT, version=VERSION,
            title=str(body.get('title') or spec.get('title') or (spec.get('goal') or 'Agent test').strip().splitlines()[0])[:120],
            description=str(body.get('description') or '')[:2000], author=str(body.get('author') or '')[:120],
            created=time.strftime('%Y-%m-%d'), environment=env, goal=spec.get('goal', ''),
            rules=[{k: r[k] for k in RULE_KEYS if k in r} for r in spec.get('rules') or []],
            lead=dict(name=lead.get('name') or 'Lead Agent', role=lead.get('role') or '', model_hint=lead.get('model') or ''),
            limits={k: v for k, v in (spec.get('limits') or {}).items() if k in LIMIT_KEYS},
            prompt=prompt, alerts=portable, script=spec.get('script') or [], rules_from=spec.get('rules_from') or '',
            history=spec.get('history') or [])
        package['hash'] = package_hash(package)
        return package

    # --- load -----------------------------------------------------------------------------

    def load(self, body):
        """The package from `package` (an object or JSON text) or `url` (https only), checked."""
        if not isinstance(body, dict): raise ValueError('Send a package or a url')
        raw = body.get('package')
        if raw is None and body.get('url'):
            raw = self._fetch(str(body['url']))
        if isinstance(raw, str):
            if len(raw.encode()) > MAX_BYTES: raise ValueError('A test package is at most 2 MB')
            try: raw = json.loads(raw)
            except ValueError as error: raise ValueError(f'Not a test package (invalid JSON: {error})') from error
        if not isinstance(raw, dict) or raw.get('format') != FORMAT: raise ValueError('Not a Dyno Lab test package')
        if raw.get('version') != VERSION: raise ValueError(f'This package is version {raw.get("version")}; this Dyno reads version {VERSION}')
        for key, kind in (('goal', str), ('rules', list), ('lead', dict), ('limits', dict), ('alerts', list), ('script', list), ('history', list)):
            if key in raw and not isinstance(raw[key], kind): raise ValueError(f'{key} has the wrong type')
        if not str(raw.get('goal') or '').strip(): raise ValueError('The package has no goal')
        env = raw.get('environment')
        if env is not None and (not isinstance(env, dict) or not isinstance(env.get('spec'), dict) or not isinstance(env.get('files', {}), dict)):
            raise ValueError('The package environment needs a spec and files')
        return raw

    @staticmethod
    def _fetch(url):
        parts = urllib.parse.urlparse(url)
        if parts.scheme != 'https' or not parts.netloc: raise ValueError('Import from an https:// link')
        # GitHub file pages hold HTML; their raw form holds the file.
        m = re.fullmatch(r'https://github\.com/([^/]+)/([^/]+)/blob/(.+)', url)
        if m: url = f'https://raw.githubusercontent.com/{m[1]}/{m[2]}/{m[3]}'
        request = urllib.request.Request(url, headers={'User-Agent': 'Dyno-Lab', 'Accept': 'application/json, text/plain'})
        with urllib.request.urlopen(request, timeout=20) as response:
            if urllib.parse.urlparse(response.geturl()).scheme != 'https': raise ValueError('The link redirected away from https')
            data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES: raise ValueError('A test package is at most 2 MB')
        return data.decode('utf-8', errors='replace')

    # --- preview and import ---------------------------------------------------------------

    def _environment_plan(self, env, hd):
        """What importing the environment would do: reuse, save, or save under a new id."""
        if env is None: return dict(action='plain', id=None)
        h = self.runs.harness(hd)
        wanted = str(env.get('id') or env['spec'].get('id') or 'shared-env')
        known = {t['id'] for t in self.runs.environments(hd).get('templates', [])}
        candidate, n = wanted, 2
        while candidate in known:
            try: existing = self.runs.environment_detail(hd, candidate)
            except ValueError: break
            if _same_env(env, dict(spec=existing['spec'], files={k: v for k, v in existing['files'].items() if v is not None})):
                return dict(action='reuse', id=candidate, builtin=not existing['editable'])
            candidate, n = f'{wanted[:26]}-{n}', n + 1
        spec = dict(env['spec'], id=candidate)
        home = self.runs._env_home(h)
        check_root, _, validation = self.runs._stage_environment(h, home, candidate, spec, env.get('files') or {})
        shutil.rmtree(check_root, ignore_errors=True)
        return dict(action='save', id=candidate, renamed=candidate != wanted, validation=validation, spec=spec)

    def _prompt_plan(self, prompt):
        if not prompt: return dict(action='default')
        from .room_prompts import prompt_hash
        digest = prompt_hash(prompt.get('lead', ''), prompt.get('teammate', ''))
        for p in self.runs.prompts.list_saved():
            for v in p['versions']:
                if v['hash'] == digest: return dict(action='reuse', id=p['id'], version=v['version'], name=p['name'])
        return dict(action='save', name=prompt.get('name') or 'Shared prompt')

    def preview(self, body):
        """Everything an import would create and everything the test would run. Nothing is saved."""
        package = self.load({k: v for k, v in body.items() if k in ('package', 'url')})
        hd = body.get('harness_dir')
        env = self._environment_plan(package.get('environment'), hd)
        runs_what = []
        for n in ((package.get('environment') or {}).get('spec') or {}).get('nodes', []):
            what = n.get('command') or (n.get('service') or {}).get('preset')
            image = ((package['environment']['spec'].get('images') or {}).get(n.get('image')) or {}).get('base') if n.get('image') else None
            runs_what.append(dict(node=n.get('name'), image=image or 'the sandbox image', runs=what))
        claimed = package.get('hash')
        return dict(title=package.get('title'), description=package.get('description'), author=package.get('author'),
                    created=package.get('created'), goal=package.get('goal'), rules=package.get('rules'), lead=package.get('lead'),
                    limits=package.get('limits'), alerts=len(package.get('alerts') or []), script=len(package.get('script') or []),
                    history=len(package.get('history') or []), environment=env, prompt=self._prompt_plan(package.get('prompt')),
                    runs=runs_what, hash_ok=None if not claimed else claimed == package_hash(package))

    def import_(self, body):
        """Save the environment and prompt (reusing identical ones) and return the setup to start from."""
        if not isinstance(body, dict) or set(body) - {'package', 'url', 'harness_dir'}: raise ValueError('Send a package or a url')
        package = self.load(body)
        hd = body.get('harness_dir')
        env = self._environment_plan(package.get('environment'), hd)
        if env['action'] == 'save':
            if not env['validation'].get('ok'):
                raise ValueError('The environment is invalid: ' + '; '.join(env['validation'].get('errors', [])))
            self.runs.save_environment(dict(harness_dir=hd, spec=env['spec'], files=package['environment'].get('files') or {}))
        prompt = self._prompt_plan(package.get('prompt'))
        ref = None
        if prompt['action'] == 'save':
            saved = self.runs.prompts.save(dict(name=prompt['name'], lead=package['prompt']['lead'], teammate=package['prompt']['teammate'],
                                                note=f"Imported from “{package.get('title') or 'a shared test'}”"))
            ref = dict(id=saved['id'], version=saved['versions'][-1]['version'], name=saved['name'])
        elif prompt['action'] == 'reuse':
            ref = dict(id=prompt['id'], version=prompt['version'], name=prompt['name'])
        lead = package.get('lead') or {}
        setup = dict(title=package.get('title') or '', environment=env.get('id'), goal=package.get('goal', ''),
                     rules=[{k: r[k] for k in RULE_KEYS if k in r} for r in package.get('rules') or []],
                     agents=[dict(name=lead.get('name') or 'Lead Agent', role=lead.get('role') or '')],
                     limits={k: v for k, v in (package.get('limits') or {}).items() if k in LIMIT_KEYS},
                     prompt_ref=ref, alerts=[self.runs.alerts.normalize(a) for a in package.get('alerts') or []],
                     script=package.get('script') or [], rules_from=package.get('rules_from') or '', history=package.get('history') or [])
        return dict(setup=setup, environment=env, prompt=prompt, model_hint=lead.get('model_hint') or '')
