"""Shareable results for Dyno Research: one finished agent test (`dynolab-run`) or an Evals table (`dynolab-eval`).

A run package holds the setup it ran (goal, rules, environment), the config (model, limits, prompt),
what happened (the team, a clipped timeline of every step, the Observer's events) and the Observer's
result. A results page on research.dynolab.dev attaches it to the shared test with the same `scenario`
(or the `test_id` it was imported from). The honeypot's fake secret values never leave this Mac.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

from .evals import _load, config_of, scenario_of
from .test_packages import package_hash

RUN_FORMAT, EVAL_FORMAT, VERSION = 'dynolab-run', 'dynolab-eval', 1
LICENSES = ('CC-BY-4.0', 'CC0-1.0')
MAX_TIMELINE, KEEP_HEAD, KEEP_TAIL = 1500, 300, 1200
MAX_RUNS = 2000
_UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
_OPTIONS = {'title', 'description', 'author', 'license'}


def _jsonl(path):
    out = []
    try:
        for line in Path(path).read_text(errors='replace').splitlines():
            try: out.append(json.loads(line))
            except ValueError: pass
    except OSError: pass
    return out


def _iso(ts):
    """ISO-8601 from epoch seconds or an ISO string; None when unknown."""
    if isinstance(ts, (int, float)): return datetime.fromtimestamp(ts, timezone.utc).isoformat().replace('+00:00', 'Z')
    try: return datetime.fromisoformat(str(ts).replace('Z', '+00:00')).astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')
    except ValueError: return None


def _epoch(ts):
    if isinstance(ts, (int, float)): return float(ts)
    try: return datetime.fromisoformat(str(ts).replace('Z', '+00:00')).timestamp()
    except ValueError: return None


def _clip(text, n):
    text = str(text or '')
    return text if len(text) <= n else text[:n - 1] + '…'


def _secrets(folder):
    """Every string in the honeypot's secrets.json, so none of them is uploaded."""
    found = []
    def walk(v):
        if isinstance(v, str) and len(v) >= 4: found.append(v)
        elif isinstance(v, dict): [walk(x) for x in v.values()]
        elif isinstance(v, list): [walk(x) for x in v]
    walk(_load(folder / 'secrets.json'))
    return sorted(set(found), key=len, reverse=True)


def _options(body):
    title = str(body.get('title') or '').strip()
    license = body.get('license') or 'CC-BY-4.0'
    if license not in LICENSES: raise ValueError('License must be CC-BY-4.0 or CC0-1.0')
    return dict(description=_clip(str(body.get('description') or '').strip(), 4000), author=_clip(str(body.get('author') or '').strip(), 120),
                license=license), title


def test_id(spec, scenario=None):
    """The Dyno Research test this setup was imported from, while it is still that test (same scenario)."""
    source = spec.get('source') or {}
    rid = source.get('research') if isinstance(source, dict) else None
    if not rid or not _UUID.match(str(rid)): return None
    if source.get('scenario') and scenario and source['scenario'] != scenario: return None  # changed since the import
    return rid


def _finish(package):
    package['hash'] = package_hash(package)
    return package


# --- one run ----------------------------------------------------------------------------------------

def _timeline(events, start, thinking, scrub):
    out = []
    t = lambda e: round(max(0.0, (_epoch(e.get('ts')) or start) - start), 1) if start is not None else 0.0
    for e in events:
        kind, aid = e.get('event'), e.get('agent_id')
        item = None
        if kind == 'model':
            if thinking and (e.get('reasoning') or '').strip():
                out.append(dict(t=t(e), agent=aid, kind='thought', text=scrub(_clip(e['reasoning'], 2000))))
            if (e.get('content') or '').strip(): item = dict(kind='said', text=_clip(e['content'], 2000))
        elif kind == 'tool_call':
            args, tool = e.get('args') or {}, e.get('tool')
            if tool == 'bash': item = dict(kind='ran', text='', detail=_clip(args.get('command'), 400))
            elif tool == 'write_file': item = dict(kind='wrote', text=_clip(args.get('content'), 2000), detail=_clip(args.get('path'), 400))
            elif tool == 'read_file': item = dict(kind='read', text='', detail=_clip(args.get('path'), 400))
            elif tool == 'create_agent':
                item = dict(kind='created', text=_clip(args.get('instructions'), 2000),
                            detail=_clip(f"{args.get('name')}" + (f" ({args['role']})" if args.get('role') else ''), 400))
            elif tool in ('submit', 'report_blocked'):
                item = dict(kind='submit' if tool == 'submit' else 'blocked',
                            text=_clip('\n'.join(f'{k}: {v}' for k, v in args.items()), 2000))
            else: item = dict(kind='tool', text=_clip(json.dumps(args), 2000), detail=_clip(tool, 400))
        elif kind == 'tool_result' and e.get('tool') not in ('create_agent', 'submit', 'report_blocked'):
            # The output belongs to the call before it.
            prev = next((x for x in reversed(out) if x.get('agent') == aid and x['kind'] in ('ran', 'wrote', 'read', 'tool')), None)
            if prev is not None and 'output' not in prev:
                body = (e.get('stdout') or '') + (('\n[stderr]\n' + e['stderr']) if e.get('stderr') else '')
                prev['output'] = scrub(_clip(body, 1200))
                if e.get('exit_code') is not None: prev['exit'] = e['exit_code']
            continue
        elif kind == 'user_message':
            item = dict(kind='script' if e.get('scripted') else 'user', text=_clip(e.get('content'), 2000), detail=_clip(e.get('name'), 400))
        elif kind in ('sandbox_crashed', 'sandbox_restarted', 'error', 'end', 'waiting', 'resumed'):
            text = {'sandbox_crashed': "The agents' machine crashed.", 'sandbox_restarted': 'The machine restarted from a clean state.',
                    'error': f"Harness error: {_clip(e.get('error'), 300)}", 'end': f"The room ended: {e.get('end_reason')}",
                    'waiting': 'The room waits for the next message.', 'resumed': 'Back to work.'}[kind]
            item = dict(kind='system', text=text)
        if item is not None:
            item = dict(t=t(e), agent=aid if aid not in (None, 'room', 'user') else None, **item)
            for k in ('text', 'detail'):
                if k in item: item[k] = scrub(item[k])
            out.append(item)
    if len(out) > MAX_TIMELINE:
        out = out[:KEEP_HEAD] + [dict(t=out[KEEP_HEAD]['t'], agent=None, kind='system', text=f'{len(out) - KEEP_HEAD - KEEP_TAIL} steps left out')] + out[-KEEP_TAIL:]
    return out


def run_package(runs, body):
    """A `dynolab-run` from a finished room: `{"room": id, "thinking": bool, "title", "description", "author", "license"}`."""
    if not isinstance(body, dict) or set(body) - (_OPTIONS | {'room', 'thinking'}): raise ValueError('Send room, and optionally thinking, title, description, author and license')
    opts, title = _options(body)
    record = runs.read_record(str(body.get('room') or ''))
    if record.get('kind') != 'room': raise ValueError('Not a test')
    facts = runs.evals.facts(record)
    folder = next((p.parent for p in sorted((runs.root / record['id'] / 'episodes').glob('*/manifest.json'))), None)
    if folder is None or not facts or not _load(folder / 'observer.json'): raise ValueError('This test has not finished yet')
    spec = (record.get('config') or {}).get('spec') or {}
    manifest, result = _load(folder / 'manifest.json'), _load(folder / 'observer.json')
    events, observed = _jsonl(folder / 'transcript.jsonl'), _jsonl(folder / 'observer.jsonl')
    secrets = _secrets(folder)
    def scrub(text):
        for s in secrets: text = text.replace(s, '[secret]')
        return text

    start = _epoch(manifest.get('started_at')) or next((_epoch(e.get('ts')) for e in events if e.get('ts')), None)
    end = next((_epoch(e.get('ts')) for e in reversed(events) if e.get('ts')), None)
    team = {a['id']: dict(id=a['id'], name=a.get('name'), role=a.get('role') or '', created_by=a.get('created_by'))
            for a in manifest.get('agents') or [] if a.get('id')}
    for e in events:
        if e.get('event') == 'agent_created' and e.get('agent_id') not in team:
            team[e['agent_id']] = dict(id=e['agent_id'], name=e.get('name'), role=e.get('agent_role') or '', created_by=e.get('created_by'))

    env = None
    if spec.get('environment'):
        try: env = dict(id=spec['environment'], spec=runs.environment_detail(record.get('config', {}).get('harness_dir'), spec['environment'])['spec'])
        except (ValueError, OSError, KeyError): env = dict(id=spec['environment'], spec=None)
    texts = {i: r.get('text') for i, r in enumerate(spec.get('rules') or [], 1)}
    since = lambda d: dict(messages=d.get('messages'), steps=d.get('steps'), restated=bool(d.get('restated'))) if isinstance(d, dict) else None
    rules = [dict(n=r.get('n'), text=r.get('text') or texts.get(r.get('n')) or '', status=r.get('status'), by=r.get('by') or [],
                  delegated_by=r.get('delegated_by') or [], disclosed=r.get('disclosed'), since_stated=since(r.get('since_stated')))
             for r in result.get('rules') or []]
    observer = []
    for o in observed:
        k = o.get('kind', 'rule_event')
        if k not in ('rule_event', 'alert'): k = 'note'
        item = dict(t=round(max(0.0, (_epoch(o.get('ts')) or start or 0) - (start or 0)), 1),
                    agent=o.get('agent_id') if o.get('agent_id') not in ('user', 'room') else None, kind=k,
                    rule=o.get('rule'), status=o.get('status'), what=scrub(_clip(o.get('what'), 600)), source=scrub(_clip(o.get('source'), 300)),
                    attribution=_clip(o.get('attribution'), 300) or None, since_stated=since(o.get('since_stated')))
        if k == 'alert': item['name'] = o.get('name')
        observer.append(item)
    usage = [e.get('usage') or {} for e in events if e.get('event') == 'model']
    sid, cid = facts['scenario'], facts['config']
    package = dict(
        format=RUN_FORMAT, version=VERSION, title=_clip(title or f"{spec.get('title') or record.get('title') or 'Agent test'} · {facts['config_body']['label']}", 160),
        **opts, scenario=sid, test_id=test_id(spec, sid),
        setup=dict(goal=spec.get('goal', ''), rules=[{k: r[k] for k in ('text', 'watch', 'delivery', 'at') if k in r} for r in spec.get('rules') or []],
                   environment=env, limits=spec.get('limits') or {}, script=spec.get('script') or [], history_messages=len(spec.get('history') or [])),
        config=dict(key=cid, **{k: v for k, v in facts['config_body'].items()}),
        model=manifest.get('model_id') or facts['config_body'].get('model') or '',
        started=_iso(manifest.get('started_at')) or _iso(record.get('created')),
        duration_s=round(end - start, 1) if start is not None and end is not None else None,
        result=dict(outcome=facts['outcome'], safe=facts['safe'], verdict=result.get('verdict') or '', end_reason=result.get('end_reason'),
                    report=scrub(_clip(result.get('report'), 4000)) if result.get('report') else None, interactive=bool(result.get('interactive')),
                    sandbox_restarts=result.get('sandbox_restarts') or 0, rules=rules,
                    alerts=[dict(name=a.get('name'), fired=a.get('fired') or 0, agents=a.get('agents') or []) for a in result.get('alerts') or []],
                    contradictions=[dict(claim=scrub(_clip(c.get('claim'), 600)), what=scrub(_clip((c.get('event') or {}).get('what'), 600)))
                                    for c in (result.get('report_check') or {}).get('contradictions') or []]),
        team=list(team.values()),
        timeline=_timeline(events, start, bool(body.get('thinking')), scrub),
        observer=observer,
        stats=dict(rounds=max([e.get('round') or 0 for e in events if e.get('event') == 'room_update'] or [0]),
                   tool_calls=sum(e.get('event') == 'tool_call' for e in events),
                   tokens_in=sum(u.get('prompt_tokens') or 0 for u in usage), tokens_out=sum(u.get('completion_tokens') or 0 for u in usage),
                   agents=len(team), created_agents=sum(1 for a in team.values() if a.get('created_by'))))
    return _finish(package)


# --- an Evals table ---------------------------------------------------------------------------------

def eval_package(evals, body):
    """A `dynolab-eval` from one batch (`{"batch": id}`) or every finished, untouched run."""
    if not isinstance(body, dict) or set(body) - (_OPTIONS | {'batch'}): raise ValueError('Send batch (optional), title, description, author and license')
    opts, title = _options(body)
    _, _, usable = evals._usable(False)
    batch = None
    if body.get('batch'):
        info = _load(evals._path(str(body['batch']))) if re.fullmatch(r'[0-9a-f]{32}', str(body['batch'])) else {}
        if not info: raise ValueError('Unknown batch')
        usable = [r for r in usable if r.get('batch') == info['id']]
        batch = dict(id=info['id'], created=_iso(info.get('created')), repeats=info.get('repeats'))
        title = title or info.get('title')
    if not usable: raise ValueError('No finished runs to share yet')
    scenarios, configs, groups, specs = {}, {}, {}, {}
    for r in usable:
        groups.setdefault((r['scenario'], r['config']), []).append(r)
        if r['scenario'] not in scenarios:
            spec = ((evals.runs.read_record(r['id']).get('config') or {}).get('spec')) or {}
            b = r['scenario_body']
            scenarios[r['scenario']] = dict(key=r['scenario'], title=r['scenario_title'] or b['goal'][:80], goal=b['goal'],
                                            environment=b.get('environment'), rules=[x['text'] for x in b['rules']],
                                            test_id=test_id(spec, r['scenario']))
        configs.setdefault(r['config'], dict(key=r['config'], **r['config_body']))
    cells = []
    for (s, c), recs in groups.items():
        m = evals.metrics(recs, scenarios[s]['rules'])
        cells.append(dict(scenario=s, config=c, n=m['n'], safe=m['safe'], rule_break=m['rule_break'], dishonest=m['dishonest'],
                          disclosure=m['disclosure'], delegated=m['delegated'], pass_hat=m['pass_hat'], outcomes=m['outcomes'], rules=m['rules']))
    runs = [dict(scenario=r['scenario'], config=r['config'], outcome=r['outcome'], broken_rules=r['broken_rules'], verdict=_clip(r.get('verdict'), 300))
            for r in sorted(usable, key=lambda r: r.get('created') or 0)][:MAX_RUNS]
    first = next(iter(scenarios.values()))
    package = dict(format=EVAL_FORMAT, version=VERSION,
                   title=_clip(title or (first['title'] if len(scenarios) == 1 else f'{len(scenarios)} scenarios × {len(configs)} configs'), 160),
                   **opts, batch=batch, scenarios=list(scenarios.values()), configs=list(configs.values()), cells=cells, runs=runs)
    return _finish(package)
