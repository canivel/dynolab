"""Saved agent prompts for rooms: Markdown templates for the lead, for created agents and for the team instruction
(which opens the lead's prompt when a test requires a team), kept
as numbered versions. A version is never changed or deleted, so every room can say exactly which
prompt it ran with and Run again repeats it."""
from __future__ import annotations

import hashlib
import json
import re
import time
import uuid

NAME = re.compile(r'^[0-9a-f]{32}$')
LIMIT = 20000


def _load(path):
    try: return json.loads(path.read_text())
    except (OSError, ValueError): return {}


def prompt_hash(lead, teammate, team=None):
    # Versions from before the team instruction hash as they always did.
    return hashlib.sha256(json.dumps([lead, teammate] + ([team] if team else [])).encode()).hexdigest()[:12]


class PromptLibrary:
    def __init__(self, runs):
        self.runs = runs
        self.folder = runs.root / 'prompts'
        self.folder.mkdir(exist_ok=True, mode=0o700)

    def _defaults(self, harness_dir):
        return self.runs.harness(harness_dir).json(['room-prompts'], timeout=30)

    def list(self, harness_dir=None):
        defaults = self._defaults(harness_dir)
        builtin = dict(id='default', name='Default', builtin=True, created=None,
                       versions=[dict(version=1, created=None, note='Built into Dyno', **defaults['prompts'],
                                      hash=prompt_hash(defaults['prompts']['lead'], defaults['prompts']['teammate']))])
        saved = sorted((p for p in (_load(f) for f in self.folder.glob('*.json')) if p), key=lambda p: p['name'].lower())
        return dict(prompts=[builtin, *saved], placeholders=defaults.get('placeholders', {}))

    def list_saved(self):
        return [p for p in (_load(f) for f in self.folder.glob('*.json')) if p]

    def get(self, identifier):
        if not NAME.match(identifier or ''): raise ValueError('Unknown prompt')
        prompt = _load(self.folder / f'{identifier}.json')
        if not prompt: raise ValueError('Unknown prompt')
        return prompt

    def save(self, body):
        """A new prompt, or a new version of a saved one. Unchanged text adds no version."""
        if not isinstance(body, dict) or set(body) - {'id', 'name', 'lead', 'teammate', 'team', 'note'}: raise ValueError('Use id, name, lead, teammate, team and note')
        name = ' '.join(str(body.get('name') or '').split())[:80]
        if not name: raise ValueError('Name the prompt')
        lead, teammate = str(body.get('lead') or ''), str(body.get('teammate') or '')
        if not lead.strip() or not teammate.strip(): raise ValueError('Write both prompts: the lead and created agents')
        # The team instruction opens the lead's prompt when a test needs a team, so it can't be blank. Left out
        # (older clients, imported packages), the harness's default instruction is used.
        team = None if body.get('team') is None else str(body['team'])
        if team is not None and not team.strip(): raise ValueError('Write the team instruction: it opens the lead\'s prompt when a test needs a team')
        team = team or None
        if max(len(lead), len(teammate), len(team or '')) > LIMIT: raise ValueError(f'A prompt can be at most {LIMIT:,} characters')
        note = str(body.get('note') or '')[:300]
        with self.runs.lock:
            prompt = self.get(body['id']) if body.get('id') else dict(id=uuid.uuid4().hex, created=time.time(), versions=[])
            prompt['name'] = name
            digest = prompt_hash(lead, teammate, team)
            if not prompt['versions'] or prompt['versions'][-1]['hash'] != digest:
                prompt['versions'].append(dict(version=len(prompt['versions']) + 1, created=time.time(), note=note,
                                               lead=lead, teammate=teammate, hash=digest, **({'team': team} if team else {})))
            path = self.folder / f"{prompt['id']}.json"; tmp = path.with_suffix('.tmp')
            tmp.write_text(json.dumps(prompt, indent=2)); tmp.replace(path)
        return prompt

    def resolve(self, ref):
        """What a room spec carries: the template texts and a reference to the saved version."""
        if ref is None or ref == {} or (isinstance(ref, dict) and ref.get('id') == 'default'):
            return None, dict(id='default', name='Default', version=1)
        if not isinstance(ref, dict) or set(ref) - {'id', 'version'} or type(ref.get('version')) is not int: raise ValueError('Choose a saved prompt and version')
        prompt = self.get(ref.get('id'))
        v = next((v for v in prompt['versions'] if v['version'] == ref['version']), None)
        if v is None: raise ValueError('That prompt version does not exist')
        texts = dict(lead=v['lead'], teammate=v['teammate'], **({'team': v['team']} if v.get('team') else {}))
        return texts, dict(id=prompt['id'], name=prompt['name'], version=v['version'], hash=v['hash'])
