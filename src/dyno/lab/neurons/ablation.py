"""Ablation by activation strength: do a unit's weak activations matter, or only its strong ones?

Each condition zeroes activations at a hook, at every position and on every forward pass:

- `below` p: each unit's activations whose |value| is below that unit's p-th percentile (weak-75: p = 75).
- `above` p: those above it (strong-7: p = 93).
- `random_mass`: a random set of activations whose expected total |value| equals what the named condition removes.
- `random_count`: a random set with as many activations as the named condition removes.
- `sae_splice`: the hook's value replaced by an SAE's reconstruction.

Percentiles and removed mass come from calibration tokens of training documents; the effects are measured on held-out
documents: how often the top next-token prediction changes, the KL divergence from the unablated model, and the change
in next-token loss, each with a bootstrap interval over contexts.
"""
from __future__ import annotations

import time
from pathlib import Path

DEFAULT_CONDITIONS = [
    dict(name='weak-75', kind='below', percentile=75),
    dict(name='weak-75 random (mass-matched)', kind='random_mass', of='weak-75'),
    dict(name='weak-75 random (count-matched)', kind='random_count', of='weak-75'),
    dict(name='strong-7', kind='above', percentile=93),
    dict(name='strong-7 random (mass-matched)', kind='random_mass', of='strong-7'),
    dict(name='strong-7 random (count-matched)', kind='random_count', of='strong-7'),
]
KINDS = ('below', 'above', 'random_mass', 'random_count', 'sae_splice')


def validate(config):
    c = dict(hook='mlp_hidden', layers='all', context=512, calibration_tokens=50_000, eval_tokens=100_000, bootstrap=1000,
             calibration_samples=4096, heldout_fraction=0.2, conditions=DEFAULT_CONDITIONS)
    c.update({k: v for k, v in config.items() if v is not None})
    names = set()
    if not isinstance(c['conditions'], list) or not 1 <= len(c['conditions']) <= 16: raise ValueError('conditions: 1–16 conditions')
    for cond in c['conditions']:
        if not isinstance(cond, dict) or cond.get('kind') not in KINDS or not isinstance(cond.get('name'), str):
            raise ValueError(f'Each condition has a name and a kind: {", ".join(KINDS)}')
        if cond['kind'] in ('below', 'above') and (type(cond.get('percentile')) not in (int, float) or not 0 < cond['percentile'] < 100):
            raise ValueError('below/above conditions need a percentile between 0 and 100')
        if cond['kind'] in ('random_mass', 'random_count') and cond.get('of') not in names:
            raise ValueError(f'{cond["name"]}: "of" must name an earlier below/above condition')
        if cond['kind'] == 'sae_splice' and not cond.get('sae'): raise ValueError('sae_splice needs sae: an SAE job id')
        names.add(cond['name'])
    for key, low, high in (('calibration_tokens', 1000, 10_000_000), ('eval_tokens', 1000, 10_000_000), ('bootstrap', 0, 10000), ('context', 16, 8192)):
        if type(c[key]) is not int or not low <= c[key] <= high: raise ValueError(f'{key} must be between {low} and {high}')
    return c


def interval(per_context, weights, draws, rng):
    """Mean over tokens, with a 95% bootstrap interval over contexts."""
    import numpy as np
    values, weights = np.asarray(per_context, float), np.asarray(weights, float)
    mean = float(values.sum() / max(weights.sum(), 1))
    if draws <= 0 or len(values) < 2: return dict(mean=mean, low=None, high=None)
    picks = rng.integers(0, len(values), size=(draws, len(values)))
    means = values[picks].sum(1) / np.maximum(weights[picks].sum(1), 1)
    return dict(mean=mean, low=float(np.quantile(means, 0.025)), high=float(np.quantile(means, 0.975)))


def run(config, folder, load_model, progress):
    import mlx.core as mx
    import numpy as np
    from . import corpus as corpora
    c = validate(config)
    started = time.time()
    rng = np.random.default_rng(c.get('seed', 0))
    model, tokenizer, model_config, captured, collecting, info = load_model(c['hook'], c['layers'])
    layers = info['layers']
    active = load_model.state['active']
    docs, corpus_provenance = corpora.documents(c['corpus'], (c['calibration_tokens'] + c['eval_tokens']) * 3, c['lab_root'], c.get('seed', 0),
                                               c['heldout_fraction'], progress=lambda m: progress(m, 0.0))
    pad = getattr(tokenizer, 'pad_token_id', None) or 0

    def batches(split, tokens, rows=8):
        source = [d for d in docs if d['heldout'] == (split == 'heldout')]
        stream = corpora.contexts(source, tokenizer, c['context'], tokens)
        while True:
            batch = [w for w in (next(stream, None) for _ in range(rows)) if w is not None]
            if not batch: return
            L = max(len(w['ids']) for w in batch)
            ids = np.full((len(batch), L), pad, 'int32'); valid = np.zeros((len(batch), L), bool)
            for i, w in enumerate(batch): ids[i, :len(w['ids'])] = w['ids']; valid[i, :len(w['ids'])] = True
            yield ids, valid

    # Calibration: a sample of |activation| per layer and unit.
    progress('Calibrating percentiles on training text', 0.02)
    samples = {layer: [] for layer in layers}
    per_batch = max(16, c['calibration_samples'] // max(1, c['calibration_tokens'] // (8 * c['context'])))
    for ids, valid in batches('train', c['calibration_tokens']):
        captured.clear(); collecting[0] = True
        model(mx.array(ids))
        positions = np.flatnonzero(valid.reshape(-1))
        pick = mx.array(rng.choice(positions, size=min(per_batch, len(positions)), replace=False))
        for layer in layers:
            samples[layer].append(np.abs(np.array(captured[layer].reshape(-1, captured[layer].shape[-1])[pick].astype(mx.float16))))
    samples = {layer: np.concatenate(v, axis=0).astype('float32') for layer, v in samples.items()}
    collecting[0] = False
    plan = {}
    for cond in c['conditions']:
        if cond['kind'] in ('below', 'above'):
            per_layer = {}
            for layer, s in samples.items():
                t = np.quantile(s, cond['percentile'] / 100, axis=0)
                removed = s < t if cond['kind'] == 'below' else s > t
                per_layer[layer] = dict(threshold=mx.array(t.astype('float32')), mass=float((s * removed).sum() / max(s.sum(), 1e-12)),
                                        count=float(removed.mean()))
            plan[cond['name']] = dict(cond, per_layer=per_layer)
        elif cond['kind'] in ('random_mass', 'random_count'):
            source = plan[cond['of']]['per_layer']
            plan[cond['name']] = dict(cond, per_layer={layer: dict(probability=v['mass' if cond['kind'] == 'random_mass' else 'count'],
                                                                     mass=v['mass'], count=v['count']) for layer, v in source.items()})
        else:
            from .sae import load_sae
            sae = load_sae(Path(c['lab_root']) / cond['sae'])
            meta_layer = __import__('json').loads((Path(c['lab_root']) / cond['sae'] / 'sae.json').read_text())['layer']
            if meta_layer not in layers: raise ValueError(f'The SAE is for layer {meta_layer}; include it in layers')
            plan[cond['name']] = dict(cond, sae=sae, sae_layer=meta_layer)

    def install(name, key):
        active.clear()
        p = plan[name]
        if p['kind'] == 'sae_splice':
            active[p['sae_layer']] = lambda h, sae=p['sae']: sae(h)
            return
        for n, layer in enumerate(layers):
            v = p['per_layer'][layer]
            if p['kind'] == 'below':
                active[layer] = lambda h, t=v['threshold']: mx.where(mx.abs(h) < t.astype(h.dtype), 0, h)
            elif p['kind'] == 'above':
                active[layer] = lambda h, t=v['threshold']: mx.where(mx.abs(h) > t.astype(h.dtype), 0, h)
            else:
                active[layer] = lambda h, q=v['probability'], k=mx.random.key(key * 1009 + n): mx.where(mx.random.uniform(shape=h.shape, key=k) < q, 0, h)

    def log_probs(logits):
        x = logits.astype(mx.float32)
        return x - mx.logsumexp(x, axis=-1, keepdims=True)

    results = {cond['name']: dict(changed=[], kl=[], ce=[], tokens=[]) for cond in c['conditions']}
    clean_ce = []
    seen = 0
    for number, (ids, valid) in enumerate(batches('heldout', c['eval_tokens'])):
        active.clear()
        clean = log_probs(model(mx.array(ids)))
        mask = valid[:, 1:] & valid[:, :-1]
        target = mx.array(ids[:, 1:])
        clean_next = clean[:, :-1]
        clean_top = mx.argmax(clean_next, axis=-1)
        clean_nll = -mx.take_along_axis(clean_next, target[..., None], axis=-1)[..., 0]
        mask_mx = mx.array(mask.astype('float32'))
        clean_ce += list(np.array((clean_nll * mask_mx).sum(1)))
        for cond in c['conditions']:
            install(cond['name'], number)
            changed = log_probs(model(mx.array(ids)))[:, :-1]
            top_changed = (mx.argmax(changed, axis=-1) != clean_top).astype(mx.float32) * mask_mx
            kl = (mx.exp(clean_next) * (clean_next - changed)).sum(-1) * mask_mx
            nll = -mx.take_along_axis(changed, target[..., None], axis=-1)[..., 0]
            r = results[cond['name']]
            r['changed'] += list(np.array(top_changed.sum(1))); r['kl'] += list(np.array(kl.sum(1)))
            r['ce'] += list(np.array(((nll - clean_nll) * mask_mx).sum(1))); r['tokens'] += list(mask.sum(1))
        active.clear()
        seen += int(mask.sum())
        progress(f'Ablations: {seen:,} of {c["eval_tokens"]:,} held-out tokens', min(0.99, 0.05 + 0.94 * seen / c['eval_tokens']))
    table = []
    for cond in c['conditions']:
        r, p = results[cond['name']], plan[cond['name']]
        row = dict(name=cond['name'], kind=cond['kind'], percentile=cond.get('percentile'), of=cond.get('of'),
                   top1_changed=interval(r['changed'], r['tokens'], c['bootstrap'], rng),
                   kl=interval(r['kl'], r['tokens'], c['bootstrap'], rng),
                   ce_delta=interval(r['ce'], r['tokens'], c['bootstrap'], rng))
        if 'per_layer' in p:
            row['removed_entries'] = float(np.mean([v['count'] if p['kind'] in ('below', 'above') else v['probability'] if p['kind'] == 'random_count' else v['probability'] for v in p['per_layer'].values()]))
            row['removed_mass'] = float(np.mean([v['mass'] if p['kind'] in ('below', 'above', 'random_mass') else v['probability'] for v in p['per_layer'].values()]))
        table.append(row)
    return dict(ablation=dict(conditions=table, layers=layers, hook=c['hook'], heldout_tokens=seen,
                              clean_ce=float(np.sum(clean_ce) / max(seen, 1)), calibration_tokens=c['calibration_tokens'],
                              seconds=time.time() - started, corpus=corpus_provenance),
                hook=info, note='Every condition acts at all positions on every forward pass. Percentiles and removed mass are calibrated on training documents; '
                               'effects are measured on held-out documents. Intervals: 95% bootstrap over contexts.')
