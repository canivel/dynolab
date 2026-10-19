"""An agent that investigates one unit's pole before labeling it, instead of labeling from a fixed set of examples.

The agent (any local model that calls tools) has three tools:

- `examples(kind, decile, count)`: atlas examples from training documents: the strongest, or those at a decile of the
  pole's maximum, or random text, with the unit's activation marked.
- `activation(text)`: the unit's activation on each token of any text it writes, measured live on the model.
- `submit(label)`: its final label.

It never sees the held-out documents used to score labels: tools read only training examples, and every transcript is
checked for held-out text after the run. The label is scored exactly as the one-shot explainer's is, so two
auto-interp runs (one-shot and agent) on the same units compare pair by pair.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

SYSTEM = (
    'You investigate one unit inside a language model to find when it fires strongly ({pole} pole: {direction}). '
    'Use the tools: look at examples, form a hypothesis, then test it by writing your own texts and measuring the unit '
    'with activation(text): include texts that should fire and texts that should not. Activations are shown as '
    '[[token|n]] with n from 1 to 10 relative to the strongest activation anywhere ({maximum:.3g}). '
    'When your hypothesis predicts the measurements, call submit with one short label in plain words (at most 15 words). '
    'You have {queries} activation measurements and {steps} steps in total. Examples exist at deciles: {deciles}.')

TOOLS = [
    {'type': 'function', 'function': {'name': 'examples', 'description': 'Excerpts from training text with the unit\'s activation marked.',
     'parameters': {'type': 'object', 'properties': {
         'kind': {'type': 'string', 'enum': ['strongest', 'decile', 'random'], 'description': 'strongest examples, examples at a decile of the maximum, or random text'},
         'decile': {'type': 'integer', 'description': 'for kind=decile: 0 (weakest tenth) to 9 (strongest tenth)'},
         'count': {'type': 'integer', 'description': 'how many, at most 10'}}, 'required': ['kind']}}},
    {'type': 'function', 'function': {'name': 'activation', 'description': 'Measure the unit on every token of a text you write.',
     'parameters': {'type': 'object', 'properties': {'text': {'type': 'string', 'description': 'up to 400 tokens'}}, 'required': ['text']}}},
    {'type': 'function', 'function': {'name': 'submit', 'description': 'Your final label for when this unit fires strongly.',
     'parameters': {'type': 'object', 'properties': {'label': {'type': 'string'}}, 'required': ['label']}}},
]


class Probe:
    """The unit's activation on new text: the model with a hook at the atlas's layer, and the unit's definition."""

    def __init__(self, load_model, capture_folder, capture_config, manifest, layer):
        import numpy as np
        self.model, self.tokenizer, _, self.captured, self.collecting, self.info = load_model(manifest['hook'], [layer])
        self.layer, self.labels = layer, manifest['units']
        directions = Path(capture_folder) / 'random-directions.npy'
        self.directions = np.load(directions) if directions.exists() else None
        self.sae = None
        sae_job = (capture_config.get('units') or {}).get('sae')
        if sae_job:
            from .sae import load_sae
            self.sae = load_sae(Path(capture_config['lab_root']) / sae_job)

    def __call__(self, unit, text, limit=400):
        import mlx.core as mx
        ids = self.tokenizer.encode(text)[:limit]
        if not ids: return [], []
        self.captured.clear()
        self.model(mx.array([ids]))
        h = self.captured[self.layer][0].astype(mx.float32)
        label = self.labels[unit]
        if label['kind'] == 'neuron': values = h[:, label['index']]
        elif label['kind'] == 'random': values = h @ mx.array(self.directions[:, label['index']])
        else: values = self.sae.encode(h)[:, label['index']]
        return ids, [float(v) for v in values.tolist()]



def investigate(c, page, pole, probe, text, chat_tools, steps=12, queries=8):
    """One agent investigation. Returns (label, transcript)."""
    p = page['poles'][pole]
    maximum = p['maximum'] or 1.0
    sign = 1 if pole == 'positive' else -1

    def marked(ids, acts):
        out = []
        for i, a in zip(ids, acts):
            piece = text.piece(i).replace('\n', '⏎')
            level = sign * a / maximum
            out.append(f'[[{piece}|{max(1, round(10 * level))}]]' if level >= 0.1 else piece)
        return ''.join(out)

    def tool(name, args):
        nonlocal used
        if name == 'examples':
            kind, count = args.get('kind', 'strongest'), max(1, min(int(args.get('count') or 5), 10))
            if kind == 'strongest': rows = p['top'][:count]
            elif kind == 'decile':
                d = int(args.get('decile', 9))
                rows = next((s['examples'] for s in p['stratified'] if s['decile'] == d), [])[:count]
                if not rows: return f'No examples at decile {d}.'
            else: rows = page.get('random', [])[:count]
            return '\n'.join(f'{n}. {marked(e["ids"], e["activations"])}' for n, e in enumerate(rows, 1)) or 'None.'
        if name == 'activation':
            if used >= queries: return 'No measurements left: submit your label.'
            used += 1
            ids, acts = probe(page['unit'], str(args.get('text', ''))[:4000])
            peak = max((sign * a for a in acts), default=0.0)
            return f'Peak: {max(0.0, peak) / maximum:.0%} of the maximum. {marked(ids, acts)}'
        return 'Unknown tool.'

    used = 0
    direction = 'large positive values' if pole == 'positive' else 'large negative values'
    deciles = ', '.join(str(s['decile']) for s in p['stratified'] if s['examples']) or 'none'
    messages = [dict(role='system', content=SYSTEM.format(pole=pole, direction=direction, maximum=maximum, queries=queries, steps=steps, deciles=deciles)),
                dict(role='user', content='Start by looking at the strongest examples.')]
    transcript = []
    for step in range(steps):
        reply = chat_tools(c['explainer'], messages, TOOLS)
        calls = reply.get('tool_calls') or []
        messages.append(dict(role='assistant', content=reply.get('content') or '', **({'tool_calls': calls} if calls else {})))
        transcript.append(dict(step=step, content=reply.get('content'), tool_calls=[dict(name=t['function']['name'], arguments=t['function']['arguments']) for t in calls]))
        if not calls:
            messages.append(dict(role='user', content='Call a tool: examples, activation, or submit with your label.'))
            continue
        for call in calls:
            name = call['function']['name']
            try: args = json.loads(call['function'].get('arguments') or '{}')
            except ValueError: args = {}
            if name == 'submit':
                return re.sub(r'\s+', ' ', str(args.get('label', ''))).strip()[:300], transcript
            result = tool(name, args)
            transcript.append(dict(step=step, tool=name, result=result[:4000]))
            left = steps - step - 1
            messages.append(dict(role='tool', tool_call_id=call.get('id', name),
                                 content=f'{result}\n({left} steps and {max(0, queries - used)} measurements left)'))
        if steps - step - 1 == 1:
            messages.append(dict(role='user', content='One step left: call submit with your label now.'))
    # Out of steps: ask for the label.
    messages.append(dict(role='user', content='You are out of steps. Reply with your label only.'))
    reply = chat_tools(c['explainer'], messages, [])
    lines = [l for l in (reply.get('content') or '').splitlines() if l.strip()]
    return (lines[0].strip()[:300] if lines else ''), transcript


def leaked(transcript, page, text, pole, window):
    """Whether any held-out example's text reached the agent (it must not)."""
    blob = json.dumps(transcript, ensure_ascii=False)
    for e in page['poles'][pole]['heldout_top'] + page.get('heldout_random', []):
        snippet = text.window(e, min(window, 12)).replace('\n', '⏎')
        if len(snippet) >= 24 and snippet in blob: return True
    return False
