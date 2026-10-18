"""Auto-interp: a model labels each unit's pole from its atlas, and a second model scores the label on held-out text.

- Explainer: sees the pole's strongest examples (and, optionally, samples across its activation range), with the tokens
  where the unit fires marked and scaled 0-10 against the pole's maximum, and writes one short label.
- Detection score: the scorer sees only the label and numbered held-out texts, half from the pole's strongest held-out
  examples and half random held-out text, and says which contain a token where the unit fires strongly. Balanced
  accuracy.
- Fuzzing score: held-out strong examples with tokens highlighted, half where the unit really fires and half at random
  tokens; the scorer says which highlights fit the label. Balanced accuracy.

Baselines in the same run: random directions in the same space (units of kind "random" in the capture), and shuffled
labels (each pole scored with another unit's label). The settings that distinguish the 2023-style method from the
improved one (poles, examples shown, window, stratified samples) are fields of the config; `compare_to` pairs two runs
unit by unit.

Prompt templates are versioned and stored with the result.
"""
from __future__ import annotations

import json
import random
import re
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TEMPLATE_VERSION = 1
EXPLAIN_SYSTEM = (
    'You study one unit inside a language model. You are shown text excerpts where the unit is active. In each excerpt, '
    'tokens where it is active are marked like [[token|7]]: the number is how strongly it fires there, from 1 to 10, '
    'relative to its strongest activation anywhere. Find what the strongly marked tokens have in common, in their '
    'context. Reply with one short label in plain words (at most 15 words) for when this unit fires strongly, for '
    'example "the word not after a modal verb" or "import lines in Python code". Do not copy the [[ ]] marks. '
    'Reply with the label and nothing else.')
DETECT_SYSTEM = (
    'A unit inside a language model has this description of when it fires strongly. You are shown numbered text '
    'excerpts. Decide for each whether it contains a token where the unit, as described, fires strongly. '
    'Reply only with a JSON list of the numbers that do, for example [2, 5]. Reply [] if none do.')
FUZZ_SYSTEM = (
    'A unit inside a language model has this description of when it fires strongly. You are shown numbered text '
    'excerpts with some tokens marked like [[token]]. Decide for each whether the marked tokens are where the unit, as '
    'described, would fire. Reply only with a JSON list of the numbers whose marks fit, for example [1, 4]. Reply [] if none do.')


def validate(config):
    c = dict(poles='both', examples=20, stratified=True, window=32, detection=10, fuzzing=10, shuffled=True, threshold=0.75,
             units={'neuron': 100, 'random': 20}, concurrency=2, max_tokens=60)
    c.update({k: v for k, v in config.items() if v is not None})
    if not c.get('atlas'): raise ValueError('atlas: the id of a finished atlas job')
    if c['poles'] not in ('both', 'positive'): raise ValueError('poles: both or positive')
    for key in ('explainer', 'scorer'):
        m = c.get(key)
        if not isinstance(m, dict) or type(m.get('port')) is not int or not 1024 <= m['port'] <= 65535 or not isinstance(m.get('model', ''), str):
            raise ValueError(f'{key}: {{"port": a local model server port, "model": optional, the model it serves}}')
        # A Dyno model server answers to the model it serves as default_model; naming another would load it.
        c[key] = dict(m, model=m.get('model') or 'default_model')
    for key, low, high in (('examples', 1, 200), ('window', 1, 1024), ('detection', 2, 100), ('fuzzing', 0, 100), ('concurrency', 1, 8)):
        if type(c[key]) is not int or not low <= c[key] <= high: raise ValueError(f'{key} must be between {low} and {high}')
    return c


def chat(model, system, user, max_tokens):
    payload = dict(model=model['model'], temperature=0, max_tokens=max_tokens, stream=False, chat_template_kwargs={'enable_thinking': False},
                   messages=[dict(role='system', content=system), dict(role='user', content=user)])
    request = urllib.request.Request(f"http://127.0.0.1:{model['port']}/v1/chat/completions", data=json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json'})
    for attempt in range(3):
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=600) as response:
                message = json.loads(response.read())['choices'][0]['message']
                text = message.get('content') or ''
                return re.sub(r'<think>.*?</think>', '', text, flags=re.S).strip()
        except Exception:
            if attempt == 2: raise
            time.sleep(2 * (attempt + 1))


def clean_label(reply):
    """The first line, without marks the explainer copied ([[token|7]] -> token) or quotes around it."""
    line = next((l for l in reply.splitlines() if l.strip()), '').strip()
    line = re.sub(r'\[\[(.*?)(\|\d+)?\]\]', r'\1', line)
    line = re.sub(r'^(label|description)\s*:\s*', '', line, flags=re.I).strip().strip('"\'').strip()
    return line[:300]


def numbers(text, count):
    match = re.search(r'\[[\d,\s]*\]', text)
    if not match: return set()
    try: return {int(n) for n in json.loads(match.group(0)) if 1 <= int(n) <= count}
    except ValueError: return set()


def balanced(predicted, truth):
    tp = sum(p and t for p, t in zip(predicted, truth)); tn = sum(not p and not t for p, t in zip(predicted, truth))
    pos, neg = sum(truth), len(truth) - sum(truth)
    rates = [r for r in ((tp / pos) if pos else None, (tn / neg) if neg else None) if r is not None]
    return dict(balanced_accuracy=sum(rates) / len(rates) if rates else None, true_positive=tp, true_negative=tn, positives=pos, negatives=neg)


class Text:
    def __init__(self, vocab):
        self.vocab = vocab

    def piece(self, i): return self.vocab.get(str(i), '')

    def window(self, example, window, marks=None):
        """The example's text up to `window` tokens before its center and all after, with optional marks {index: label}."""
        ids, center = example['ids'], example['center']
        start = max(0, center - window)
        out = []
        for k in range(start, len(ids)):
            piece = self.piece(ids[k]).replace('\n', '⏎')
            if marks and k in marks: piece = f'[[{piece}{marks[k]}]]'
            out.append(piece)
        return ''.join(out)


def explain_prompt(text, pole, page, c):
    p = page['poles'][pole]
    maximum = p['maximum'] or 1.0
    sign = 1 if pole == 'positive' else -1
    shown = p['top'][:c['examples']]
    if c['stratified']:
        for d in p['stratified']:
            shown += d['examples'][:2]
    lines = []
    for n, e in enumerate(shown, 1):
        acts = e['activations']
        marks = {k: f'|{max(1, round(10 * sign * a / maximum))}' for k, a in enumerate(acts) if sign * a / maximum >= 0.1}
        lines.append(f'{n}. {text.window(e, c["window"], marks)}')
    rate = p['per_100_tokens']
    header = (f'It reaches half its maximum about {rate["50%"]:.3g} times per 100 tokens of text, and a tenth of it '
              f'{rate["10%"]:.3g} times.\n\n')
    return header + '\n'.join(lines)


def score_pole(c, page, pole, label, text, rng, kind='detection'):
    p = page['poles'][pole]
    maximum = p['maximum'] or 1.0
    sign = 1 if pole == 'positive' else -1
    if kind == 'detection':
        positives = p['heldout_top'][:c['detection'] // 2]
        negatives = [e for e in page.get('heldout_random', []) if sign * e['value'] < 0.25 * maximum][:c['detection'] - len(positives)]
        items = [(e, True) for e in positives] + [(e, False) for e in negatives]
        if not positives or not negatives: return None
        rng.shuffle(items)
        user = f'Description: {label}\n\n' + '\n'.join(f'{n}. {text.window(e, c["window"])}' for n, (e, _) in enumerate(items, 1))
        picked = numbers(chat(c['scorer'], DETECT_SYSTEM, user, 80), len(items))
    else:
        strong = p['heldout_top'][:c['fuzzing']] or p['top'][:c['fuzzing']]
        if len(strong) < 2: return None
        items = []
        for n, e in enumerate(strong):
            acts = e['activations']
            real = [k for k, a in enumerate(acts) if sign * a >= 0.3 * maximum] or [e['center']]
            if n % 2 == 0:
                items.append((text.window(e, c['window'], {k: '' for k in real}), True))
            else:
                start = max(0, e['center'] - c['window'])
                choices = [k for k in range(start, len(e['ids'])) if k not in real]
                fake = rng.sample(choices, min(len(real), len(choices))) if choices else real
                items.append((text.window(e, c['window'], {k: '' for k in fake}), False))
        rng.shuffle(items)
        user = f'Description: {label}\n\n' + '\n'.join(f'{n}. {t}' for n, (t, _) in enumerate(items, 1))
        picked = numbers(chat(c['scorer'], FUZZ_SYSTEM, user, 80), len(items))
    truth = [t for _, t in items]
    return dict(balanced([n in picked for n in range(1, len(items) + 1)], truth), shown=len(items))


def pick_units(c, index, rng):
    by_kind = {}
    for u in index['units']: by_kind.setdefault(u['kind'], []).append(u['unit'])
    spec = c['units']
    if isinstance(spec, list): return [u for u in spec]
    chosen = []
    for kind, count in spec.items():
        pool = by_kind.get(kind, [])
        chosen += sorted(rng.sample(pool, min(count, len(pool)))) if count != 'all' else pool
    return chosen


def paired(a_rows, b_rows, threshold):
    """Paired comparison of detection scores for the poles both runs scored: mean difference, pass rates, and a
    two-sided sign-flip permutation test."""
    import numpy as np
    key = lambda r: (r['layer'], r['kind'], r['index'], r['pole'])
    a = {key(r): r['detection']['balanced_accuracy'] for r in a_rows if r.get('detection') and r['detection']['balanced_accuracy'] is not None}
    b = {key(r): r['detection']['balanced_accuracy'] for r in b_rows if r.get('detection') and r['detection']['balanced_accuracy'] is not None}
    shared = sorted(set(a) & set(b))
    if not shared: return None
    diff = np.array([a[k] - b[k] for k in shared])
    rng = np.random.default_rng(0)
    flips = rng.choice([-1, 1], size=(10000, len(diff)))
    observed = abs(diff.mean())
    p = float((np.abs((flips * diff).mean(1)) >= observed - 1e-12).mean())
    return dict(poles=len(shared), mean_difference=float(diff.mean()), this_pass_rate=float(np.mean([a[k] >= threshold for k in shared])),
                other_pass_rate=float(np.mean([b[k] >= threshold for k in shared])), p_value=p)


def run(config, folder, progress):
    import numpy as np
    from .atlas import read_page
    c = validate(config)
    started = time.time()
    root = Path(c['lab_root'])
    atlas_folder = root / c['atlas']
    meta = json.loads((atlas_folder / 'atlas' / 'atlas.json').read_text())
    layer = c.get('layer', meta['layers'][0])
    if layer not in meta['layers']: raise ValueError(f"The atlas has layers {meta['layers']}")
    if c['window'] > meta['window_before']: raise ValueError(f"window: the capture kept {meta['window_before']} tokens before each example")
    index = json.loads((atlas_folder / 'atlas' / f'index-L{layer}.json').read_text())
    text = Text(json.loads((atlas_folder / 'atlas' / f'vocab-L{layer}.json').read_text()))
    rng = random.Random(c.get('seed', 0))
    units = pick_units(c, index, rng)
    poles = ('positive', 'negative') if c['poles'] == 'both' else ('positive',)
    jobs = [(u, pole) for u in units for pole in poles]
    rows, lock, done = [], threading.Lock(), [0]

    def work(item):
        unit, pole = item
        page = read_page(atlas_folder, layer, unit)
        local = random.Random(hash((c.get('seed', 0), unit, pole)) & 0xffffffff)
        row = dict(layer=layer, unit=unit, kind=page['kind'], index=page['index'], pole=pole, maximum=page['poles'][pole]['maximum'])
        if page['poles'][pole]['maximum'] <= 1e-6 or not page['poles'][pole]['top']:
            row['skipped'] = 'This pole never fires'
        else:
            try:
                reply = chat(c['explainer'], EXPLAIN_SYSTEM, explain_prompt(text, pole, page, c), c['max_tokens'])
                row['label'] = clean_label(reply)
                row['detection'] = score_pole(c, page, pole, row['label'], text, local, 'detection')
                if c['fuzzing']: row['fuzzing'] = score_pole(c, page, pole, row['label'], text, local, 'fuzzing')
            except Exception as error:  # noqa: BLE001 - one failed call shouldn't end the run
                row['error'] = str(error)[:300]
        with lock:
            rows.append(row); done[0] += 1
            progress(f'Labeled and scored {done[0]:,} of {len(jobs):,} poles', 0.9 * done[0] / len(jobs))

    with ThreadPoolExecutor(max_workers=c['concurrency']) as pool:
        list(pool.map(work, jobs))
    rows.sort(key=lambda r: (r['unit'], r['pole']))
    labeled = [r for r in rows if r.get('label')]
    if c['shuffled'] and len(labeled) > 1:
        progress('Shuffled-label baseline', 0.92)
        labels = [r['label'] for r in labeled]
        shift = rng.randrange(1, len(labels))
        def shuffled(n_row):
            n, r = n_row
            page = read_page(atlas_folder, layer, r['unit'])
            try: r['shuffled_detection'] = score_pole(c, page, r['pole'], labels[(n + shift) % len(labels)], text, random.Random(n), 'detection')
            except Exception as error: r['shuffled_error'] = str(error)[:300]
        with ThreadPoolExecutor(max_workers=c['concurrency']) as pool:
            list(pool.map(shuffled, enumerate(labeled)))

    def summary(group, key='detection'):
        scores = [r[key]['balanced_accuracy'] for r in group if r.get(key) and r[key]['balanced_accuracy'] is not None]
        if not scores: return None
        return dict(poles=len(scores), pass_rate=float(np.mean([s >= c['threshold'] for s in scores])), mean=float(np.mean(scores)),
                    median=float(np.median(scores)), histogram=np.histogram(scores, bins=10, range=(0, 1))[0].tolist())
    by_kind = {}
    for kind in sorted({r['kind'] for r in rows}):
        group = [r for r in rows if r['kind'] == kind]
        by_kind[kind] = dict(detection=summary(group), fuzzing=summary(group, 'fuzzing'), shuffled_labels=summary(group, 'shuffled_detection'),
                             by_pole={pole: summary([r for r in group if r['pole'] == pole]) for pole in poles})
    result = dict(autointerp=dict(atlas=c['atlas'], layer=layer, condition=c.get('condition'), settings={k: c[k] for k in ('poles', 'examples', 'stratified', 'window', 'detection', 'fuzzing', 'threshold')},
                                  explainer=c['explainer'], scorer=c['scorer'], summary=by_kind, poles=len(rows),
                                  errors=sum(1 for r in rows if r.get('error')), seconds=time.time() - started,
                                  templates=dict(version=TEMPLATE_VERSION, explain=EXPLAIN_SYSTEM, detect=DETECT_SYSTEM, fuzz=FUZZ_SYSTEM)),
                  note='Detection: balanced accuracy on held-out texts (half the pole\'s strongest held-out examples, half random held-out text). '
                       'A pole passes at the threshold. Random directions and shuffled labels are baselines from the same pipeline.')
    capture_units = json.loads((root / meta['capture'] / 'job.json').read_text())['config'].get('units') or {}
    if capture_units.get('sae') and (root / capture_units['sae'] / 'sae-alignment.json').exists():
        aligned = {f['feature']: f for f in json.loads((root / capture_units['sae'] / 'sae-alignment.json').read_text())['features']}
        sae_rows = [r for r in rows if r['kind'] == 'sae' and r.get('detection') and r['detection']['balanced_accuracy'] is not None]
        interpretable = [r for r in sae_rows if r['detection']['balanced_accuracy'] >= c['threshold']]
        new = [r for r in interpretable if aligned.get(r['index'], {}).get('candidate_new_building_block')]
        result['autointerp']['sae_new_building_blocks'] = dict(scored=len(sae_rows), interpretable=len(interpretable), new_building_blocks=len(new),
                                                               share_of_interpretable=len(new) / max(len(interpretable), 1),
                                                               features=[r['index'] for r in new])
    if c.get('compare_to'):
        other = json.loads((root / c['compare_to'] / 'autointerp.json').read_text())
        result['autointerp']['paired_with'] = dict(job=c['compare_to'], neuron=paired([r for r in rows if r['kind'] == 'neuron'],
                                                                                      [r for r in other['rows'] if r['kind'] == 'neuron'], c['threshold']))
    (Path(folder) / 'autointerp.json').write_text(json.dumps(dict(rows=rows, settings=result['autointerp']['settings']), ensure_ascii=False))
    return result
