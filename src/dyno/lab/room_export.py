"""Exporting a room: a readable Markdown log of the whole conversation, or a zip of its raw files."""
from __future__ import annotations

import json
import time
import zipfile
from datetime import datetime
from pathlib import Path

# The honeypot's fake secret values stay on this machine.
_LEFT_OUT = {'secrets.json'}


def _load(path):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return {}


def _jsonl(path):
    out = []
    try:
        for line in Path(path).read_text(errors='replace').splitlines():
            try: out.append(json.loads(line))
            except ValueError: pass
    except OSError: pass
    return out


def _when(ts):
    try: return datetime.fromisoformat(str(ts).replace('Z', '+00:00')).astimezone().strftime('%H:%M:%S')
    except ValueError: return ''


def _fence(text, lang=''):
    text = str(text or '').rstrip()
    ticks = '````' if '```' in text else '```'
    return f'{ticks}{lang}\n{text}\n{ticks}'


def _quote(text):
    return '\n'.join('> ' + line for line in str(text or '').strip().splitlines()) or '>'


def markdown(run, folder, thinking=True, observer=True):
    """The room as one Markdown document: setup, every turn of every agent, and the Observer."""
    spec = (run.get('config') or {}).get('spec') or {}
    manifest, result = _load(folder / 'manifest.json'), _load(folder / 'observer.json')
    events, observed = _jsonl(folder / 'transcript.jsonl'), _jsonl(folder / 'observer.jsonl')
    names = {a['id']: a for a in manifest.get('agents') or []}
    for e in events:
        if e.get('event') == 'agent_created': names.setdefault(e['agent_id'], dict(name=e.get('name'), role=e.get('agent_role')))
    who = lambda i: (names.get(i) or {}).get('name') or i or 'Room'
    prompt = manifest.get('prompt') or {}
    lines = [f"# {run.get('title') or 'Room'}", '',
             f"- **Started:** {datetime.fromtimestamp(run.get('created') or time.time()).strftime('%Y-%m-%d %H:%M')}",
             f"- **Status:** {run.get('status')}" + (f" · {manifest.get('end_reason')}" if manifest.get('end_reason') else ''),
             f"- **Environment:** {spec.get('environment') or 'plain machine'}",
             f"- **Model:** {manifest.get('model_id') or ''}",
             f"- **Agent prompt:** {prompt.get('name', 'Default')} v{prompt.get('version', 1)}",
             f"- **Team:** " + ', '.join(f"{a.get('name')}" + (f" ({a['role']})" if a.get('role') else '') +
                                          (f", created by {who(a['created_by'])}" if a.get('created_by') else '') for a in names.values()),
             f"- **Room id:** `{run.get('id')}`", '']
    if result.get('verdict'): lines += [f"**Verdict:** {result['verdict']}", '']
    lines += ['## Goal', '', str(spec.get('goal') or ''), '', '## Rules', '']
    lines += [f"{i}. {r.get('text')}" for i, r in enumerate(spec.get('rules') or [], 1)] + ['', '## Conversation', '']

    for e in events:
        kind, aid, at = e.get('event'), e.get('agent_id'), _when(e.get('ts'))
        if kind == 'start':
            for a in e.get('agents') or []:
                lines += [f"<details><summary>System prompt: {a.get('name')}</summary>", '', _fence(a.get('system_prompt')), '', '</details>', '']
        elif kind == 'room_update':
            lines += [f"### {who(aid)} · round {e.get('round')} · {at}", '', '**Received:**', '', _quote(e.get('content')), '']
        elif kind == 'model':
            usage = e.get('usage') or {}
            if thinking and (e.get('reasoning') or '').strip():
                lines += [f"<details><summary>Thinking ({who(aid)}, private)</summary>", '', _quote(e['reasoning']), '', '</details>', '']
            if (e.get('content') or '').strip():
                lines += [f"**{who(aid)} said:**", '', _quote(e['content']), '']
            if usage.get('completion_tokens'):
                lines += [f"_{usage.get('prompt_tokens', '?')} tokens in, {usage['completion_tokens']} out_", '']
        elif kind == 'tool_call':
            args, tool = e.get('args') or {}, e.get('tool')
            if tool == 'bash': lines += [f"**{who(aid)} ran:**", '', _fence(args.get('command'), 'bash'), '']
            elif tool == 'write_file': lines += [f"**{who(aid)} wrote `{args.get('path')}`:**", '', _fence(args.get('content')), '']
            elif tool == 'read_file': lines += [f"**{who(aid)} read `{args.get('path')}`**", '']
            elif tool == 'create_agent':
                lines += [f"**{who(aid)} created {args.get('name')}** ({args.get('role') or 'no role'}):", '', _quote(args.get('instructions')), '']
            elif tool in ('submit', 'report_blocked'):
                lines += [f"#### {'Final report' if tool == 'submit' else 'Reported blocked'} by {who(aid)}", '',
                          *[_quote(f"**{k}:** {v}") + '\n' for k, v in args.items()]]
            else: lines += [f"**{who(aid)} called {tool}:**", '', _fence(json.dumps(args, indent=2), 'json'), '']
        elif kind == 'tool_result' and e.get('tool') not in ('create_agent',):
            out = (e.get('stdout') or '') + (('\n[stderr]\n' + e['stderr']) if e.get('stderr') else '')
            lines += [f"_exit {e.get('exit_code')} · {e.get('duration_s')}s_", '', _fence(out or '(no output)', 'text'), '']
        elif kind == 'tool_result':
            lines += [f"_{e.get('stdout')}_", '']
        elif kind == 'agent_created':
            lines += [f"<details><summary>System prompt: {e.get('name')}</summary>", '', _fence(e.get('system_prompt')), '', '</details>', '']
        elif kind == 'user_message':
            lines += [f"### {e.get('name')} (you) · {at}", '', _quote(e.get('content')), '']
        elif kind in ('waiting', 'resumed', 'sandbox_crashed', 'sandbox_restarted', 'error', 'end'):
            text = {'waiting': 'The room waits for a follow-up message.', 'resumed': 'Back to work.',
                    'sandbox_crashed': "The agents' machine crashed.", 'sandbox_restarted': 'The machine restarted from a clean state.',
                    'error': f"Harness error: {e.get('error')}", 'end': f"The room ended: {e.get('end_reason')}"}[kind]
            lines += [f"---", f"_{at} · {text}_", '']

    if observer:
        lines += ['## Observer (hidden from the agents)', '']
        for o in observed:
            k = o.get('kind', 'rule_event')
            if k == 'rule_event':
                lines.append(f"- {_when(o.get('ts'))} · **{'Rule ' + str(o['rule']) if o.get('rule') else 'Not in the rules'} {o.get('status')}** · "
                             f"{o.get('what')} · `{o.get('source')}`" + (f" · {o['attribution']}" if o.get('created_by') else ''))
            elif k == 'alert':
                lines.append(f"- {_when(o.get('ts'))} · **Alert: {o.get('name')}** · {o.get('what')}")
            else:
                lines.append(f"- {_when(o.get('ts'))} · {o.get('what')}")
        if not observed: lines.append('- Nothing was flagged.')
        lines.append('')
        if result:
            lines += ['### Rules', ''] + [f"- Rule {r['n']}: **{r['status']}**" + (f" by {', '.join(r['by'])}" if r.get('by') else '') +
                                          (f" · delegated by {', '.join(r['delegated_by'])}" if r.get('delegated_by') else '') +
                                          ('' if r.get('disclosed') is None else ' · disclosed' if r['disclosed'] else ' · not disclosed')
                                          for r in result.get('rules') or []] + ['']
            for c in (result.get('report_check') or {}).get('contradictions') or []:
                lines += [f"- Report says “{c['claim']}”, contradicted by: {c['event'].get('what')}"]
            for a in result.get('alerts') or []:
                lines += [f"- Alert **{a['name']}** fired {a['fired']} time(s)" + (f" for {', '.join(a['agents'])}" if a.get('agents') else '')]
            lines += ['', f"**Verdict:** {result.get('verdict')}", '']
    lines += ['---', f"_Exported from Dyno Lab on {datetime.now().strftime('%Y-%m-%d %H:%M')}._", '']
    return '\n'.join(lines)


def export(runs, identifier, fmt, thinking=True, observer=True):
    """Writes the export into the run's exports folder and returns where it is."""
    record = runs.read_record(identifier)
    if record.get('kind') != 'room': raise ValueError('Not a room')
    root = runs.root / identifier
    folder = next((p.parent for p in sorted((root / 'episodes').glob('*/manifest.json'))), None)
    if folder is None: raise ValueError('This test has no log yet')
    out = root / 'exports'; out.mkdir(exist_ok=True, mode=0o700)
    stem = ''.join(c if c.isalnum() else '-' for c in (record.get('title') or 'room'))[:50].strip('-').lower() or 'room'
    stem += '-' + datetime.fromtimestamp(record.get('created') or time.time()).strftime('%Y%m%d-%H%M')
    if fmt == 'md':
        path = out / f'{stem}.md'
        path.write_text(markdown(record, folder, thinking=thinking, observer=observer))
    elif fmt == 'zip':
        path = out / f'{stem}.zip'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
            for f in sorted(root.rglob('*')):
                if f.is_file() and f.name not in _LEFT_OUT and 'exports' not in f.relative_to(root).parts:
                    z.write(f, Path(stem) / f.relative_to(root))
            z.writestr(str(Path(stem) / 'full-log.md'), markdown(record, folder))
    else: raise ValueError('Format must be md or zip')
    return dict(path=str(path), filename=path.name, bytes=path.stat().st_size)
