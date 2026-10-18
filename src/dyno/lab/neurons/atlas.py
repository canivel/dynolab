"""An atlas of a capture: for every unit and each pole, its strongest examples, samples across its activation range,
and how often it fires, on the unit's own scale.

Activations are shown as a fraction of the pole's maximum and as how often the unit reaches a level per 100 tokens,
not only as percentiles: a percentile view makes a unit that is near zero almost everywhere look arbitrary.
The positive and negative poles are separate entries and are never merged.

Files: `atlas/index-L{layer}.json` (one summary per unit), `atlas/L{layer}/{unit}.json.gz` (gzipped; examples: token ids and the
unit's activation on each) and `atlas/vocab-L{layer}.json` (the text of every token id used). Held-out examples are stored apart, for scoring labels.
"""
from __future__ import annotations

import gzip
import json
import time
from pathlib import Path

DECILES = 10


def tokenizer_for(model, revision=None):
    from mlx_lm.utils import _download, load_tokenizer
    return load_tokenizer(_download(model, revision=revision))


class Decoder:
    """Examples keep token ids; each layer's vocabulary file maps the ids used to their text."""
    def __init__(self, tokenizer):
        self.tokenizer, self.cache = tokenizer, {}

    def __call__(self, ids):
        out = []
        for i in ids:
            i = int(i)
            if i < 0: continue
            if i not in self.cache: self.cache[i] = self.tokenizer.decode([i])
            out.append(i)
        return out

    def text(self, ids):
        return ''.join(self.cache.get(int(i)) or self.tokenizer.decode([int(i)]) for i in ids)


def _example(decode, ids, acts, value, where, before, maximum):
    present = [k for k, i in enumerate(ids) if i >= 0]
    tokens = decode(ids)
    center = before - sum(1 for i in ids[:before] if i < 0)
    return dict(value=round(float(value), 3), fraction=round(float(abs(value)) / maximum, 3) if maximum else 0.0,
                ids=tokens, activations=[round(float(acts[k]), 2) for k in present], center=center,
                context=int(where[0]), position=int(where[1]))


def rate(at_least, levels, threshold):
    """Share of tokens at or above `threshold`, interpolated (log-linear) between the counted levels."""
    import numpy as np
    if threshold <= levels[0]: return float(at_least[0])
    if threshold >= levels[-1]: return float(at_least[-1])
    x = np.log(np.array(levels))
    i = int(np.searchsorted(x, np.log(threshold))) - 1
    t = (np.log(threshold) - x[i]) / (x[i + 1] - x[i])
    a, b = float(at_least[i]), float(at_least[i + 1])
    return float(np.exp((1 - t) * np.log(a) + t * np.log(b))) if a > 0 and b > 0 else (1 - t) * a + t * b


def summarize(s, unit, pole_index, manifest, tokens):
    """On the pole's own scale: its maximum, and how often it reaches 10%, 25% and 50% of it, per 100 tokens."""
    maximum = float(s['maximum'][unit, pole_index])
    out = dict(maximum=round(maximum, 4), histogram=s['histogram'][unit, pole_index].tolist())
    if 'at_least' in s and maximum > 0:
        counts = s['at_least'][unit, pole_index]
        out['per_100_tokens'] = {f'{int(f * 100)}%': round(100 * rate(counts, manifest['levels'], f * maximum) / max(tokens, 1), 4)
                                 for f in (0.1, 0.25, 0.5)}
    else:
        out['per_100_tokens'] = {'10%': 0.0, '25%': 0.0, '50%': 0.0}
    return out


def unit_page(s, unit, label, manifest, decode, per_decile):
    import numpy as np
    before = manifest['window_before']
    tokens = int(s['count'][0])
    page = dict(unit=unit, kind=label['kind'], index=label['index'], edges=manifest['edges'], poles={})
    for p_index, pole in enumerate(('positive', 'negative')):
        info = summarize(s, unit, p_index, manifest, tokens)
        maximum = info['maximum']

        def examples(name, limit=None):
            keys, values = s[f'{name}_key'][unit], s[f'{name}_value'][unit]
            out = []
            for k in range(len(keys)):
                if not np.isfinite(keys[k]): continue
                out.append(_example(decode, s[f'{name}_ids'][unit, k], s[f'{name}_acts'][unit, k], values[k], s[f'{name}_where'][unit, k], before, maximum))
            return out[:limit] if limit else out

        top = sorted(examples(f'top_{pole}'), key=lambda e: -abs(e['value']))
        samples = []
        for b in range(len(manifest['edges']) + 1):
            samples += [e for e in examples(f'bucket_{pole}_{b}') if (e['value'] > 0) == (pole == 'positive')]
        by_decile = {}
        for e in samples:
            d = min(int(e['fraction'] * DECILES), DECILES - 1)
            by_decile.setdefault(d, []).append(e)
        stratified = [dict(decile=d, range=[d / DECILES, (d + 1) / DECILES], examples=sorted(v, key=lambda e: -abs(e['value']))[:per_decile])
                      for d, v in sorted(by_decile.items(), reverse=True)]
        heldout_top = sorted(examples(f'heldout_top_{pole}'), key=lambda e: -abs(e['value']))
        if maximum <= 1e-9:  # a pole that never fires (an SAE feature's negative side) has no examples
            top, stratified, heldout_top = [], [], []
        page['poles'][pole] = dict(info, top=top, stratified=stratified, heldout_top=heldout_top)
    maxima = s['maximum'][unit]
    page['random'] = examples_random = []
    for name in ('random', 'heldout_random'):
        keys = s[f'{name}_key'][unit]
        rows = [_example(decode, s[f'{name}_ids'][unit, k], s[f'{name}_acts'][unit, k], s[f'{name}_value'][unit, k], s[f'{name}_where'][unit, k],
                         before, float(maxima.max())) for k in range(len(keys)) if np.isfinite(keys[k])]
        page['random' if name == 'random' else 'heldout_random'] = rows
    mean = s['sum'][unit] / max(tokens, 1)
    page['mean'], page['std'] = float(mean), float(np.sqrt(max(s['sum_squares'][unit] / max(tokens, 1) - mean ** 2, 0)))
    return page


def run(config, folder, progress):
    import numpy as np
    started = time.time()
    folder = Path(folder)
    source = Path(config['lab_root']) / str(config.get('capture', ''))
    if not config.get('capture') or not (source / 'capture-manifest.json').exists():
        raise ValueError('capture: the id of a finished capture job')
    manifest = json.loads((source / 'capture-manifest.json').read_text())
    capture_config = json.loads((source / 'job.json').read_text())['config']
    layers = config.get('layers') or manifest['layers']
    if any(layer not in manifest['layers'] for layer in layers): raise ValueError(f"The capture has layers {manifest['layers']}")
    wanted = config.get('units')
    labels = manifest['units']
    chosen = range(len(labels)) if not wanted else [u for u in wanted if 0 <= u < len(labels)]
    per_decile = int(config.get('samples_per_decile', 4))
    decode = Decoder(tokenizer_for(capture_config['model'], capture_config.get('revision')))
    out = folder / 'atlas'
    total = len(layers) * len(chosen)
    done = 0
    summary = {}
    for layer in layers:
        s = dict(np.load(source / f'capture-layer-{layer}.npz'))
        (out / f'L{layer}').mkdir(parents=True, exist_ok=True)
        index = []
        tokens = int(s['count'][0])
        for unit in chosen:
            page = unit_page(s, unit, labels[unit], manifest, decode, per_decile)
            (out / f'L{layer}' / f'{unit}.json.gz').write_bytes(gzip.compress(json.dumps(page, ensure_ascii=False, separators=(',', ':')).encode(), 6))
            entry = dict(unit=unit, kind=labels[unit]['kind'], index=labels[unit]['index'])
            for pole in ('positive', 'negative'):
                p = page['poles'][pole]
                entry[pole] = dict(maximum=p['maximum'], per_100_tokens=p['per_100_tokens'],
                                   preview=[decode.text([e['ids'][e['center']]]) if e['center'] < len(e['ids']) else '' for e in p['top'][:6]])
            index.append(entry)
            done += 1
            if done % 50 == 0: progress(f'Atlas: {done:,} of {total:,} units', done / total)
        (out / f'vocab-L{layer}.json').write_text(json.dumps({str(k): v for k, v in decode.cache.items()}, ensure_ascii=False))
        (out / f'index-L{layer}.json').write_text(json.dumps(dict(layer=layer, hook=manifest['hook'], tokens=tokens, units=index), ensure_ascii=False))
        summary[str(layer)] = dict(units=len(index), tokens=tokens)
    (out / 'atlas.json').write_text(json.dumps(dict(capture=config['capture'], model=capture_config['model'], hook=manifest['hook'],
                                                    layers=layers, window_before=manifest['window_before'], window_after=manifest['window_after'],
                                                    tokens=manifest['tokens'], edges=manifest['edges'])))
    return dict(atlas=dict(capture=config['capture'], model=capture_config['model'], hook=manifest['hook'], layers=summary,
                           seconds=time.time() - started),
                note='Both poles are kept apart. Levels are fractions of each pole\'s maximum; per-100-token rates are interpolated from counts at 1/8-decade levels.')


def read_page(folder, layer, unit):
    """One unit's atlas page from an atlas job folder."""
    return json.loads(gzip.decompress((Path(folder) / 'atlas' / f'L{int(layer)}' / f'{int(unit)}.json.gz').read_bytes()))
