"""Sparse autoencoders at real scale, trained on activations streamed from the model, and how their features relate to
the model's own neurons.

Architectures: `topk` (each token keeps its k largest features), `batchtopk` (a batch keeps its k x batch largest; a
learned threshold replaces it at inference) and `relu` (ReLU with an L1 penalty weighted by decoder norms).
Training streams the corpus through the model into a shuffled buffer, with a learning-rate warmup and decay, unit-norm
decoder rows and an auxiliary loss that revives dead features (TopK variants).

Evaluation on held-out documents: fraction of variance unexplained, L0, dead features, and the share of the model's
next-token loss recovered when the SAE's reconstruction replaces the hook's value (0 = as bad as zeroing it, 1 = as good
as the original).

Alignment (hooks with a neuron basis, i.e. `mlp_hidden`): for every feature, its best single neuron by correlation,
the R^2 of its best 1- and 5-neuron linear fits, how much of its decoder vector sits in its top 1 and 5 neurons, and
whether it is a candidate new building block (no neuron or small group explains it). And the reverse: for every neuron,
the features it takes part in.
"""
from __future__ import annotations

import json
import math
import os
import time
from pathlib import Path

ARCHITECTURES = ('topk', 'batchtopk', 'relu')


def defaults(config):
    c = dict(hook='mlp_hidden', context=1024, tokens=20_000_000, architecture='topk', expansion=4, k=32, l1=5.0,
             learning_rate=None, batch=4096, buffer_tokens=262144, warmup_steps=1000, decay_fraction=0.2, aux_k=512,
             aux_coefficient=1 / 32, dead_tokens=5_000_000, seeds=[0], eval_tokens=100_000, alignment=True,
             heldout_fraction=0.2, corr_threshold=0.5, r2_threshold=0.5)
    c.update({k: v for k, v in config.items() if v is not None})
    return c


def validate(config):
    c = defaults(config)
    if c['architecture'] not in ARCHITECTURES: raise ValueError(f'architecture must be one of {", ".join(ARCHITECTURES)}')
    if not isinstance(c.get('layers'), list) or len(c['layers']) != 1: raise ValueError('An SAE is trained on one layer: layers: [n]')
    for key, low, high in (('tokens', 10_000, 2_000_000_000), ('k', 1, 4096), ('batch', 64, 65536), ('buffer_tokens', 4096, 4_000_000),
                           ('eval_tokens', 1000, 10_000_000), ('context', 16, 32768), ('warmup_steps', 0, 100000), ('aux_k', 0, 65536)):
        if type(c[key]) is not int or not low <= c[key] <= high: raise ValueError(f'{key} must be an integer between {low} and {high}')
    if c.get('width') is not None and (type(c['width']) is not int or not 16 <= c['width'] <= 131072): raise ValueError('width must be 16–131072')
    if not isinstance(c['seeds'], list) or not 1 <= len(c['seeds']) <= 3 or any(type(s) is not int for s in c['seeds']):
        raise ValueError('seeds: a list of 1–3 integers')
    return c


class SAE:
    """Weights and the encode/decode used everywhere (training, splicing, capture units). Inputs are in the hook's
    own scale; the SAE works on inputs divided by `scale`."""

    def __init__(self, weights, meta):
        import mlx.core as mx
        self.W_enc, self.b_enc, self.W_dec, self.b_dec = (weights[k] for k in ('W_enc', 'b_enc', 'W_dec', 'b_dec'))
        self.meta = meta
        self.scale = float(meta['scale'])
        self.architecture, self.k = meta['architecture'], int(meta['k'])
        self.threshold = float(meta.get('threshold') or 0.0)
        self.width, self.width_in = int(self.W_enc.shape[1]), int(self.W_enc.shape[0])
        self.mx = mx

    def pre(self, x):
        mx = self.mx
        return (x.astype(mx.float32) / self.scale - self.b_dec) @ self.W_enc + self.b_enc

    def encode(self, x):
        mx = self.mx
        pre = self.pre(x)
        act = mx.maximum(pre, 0)
        if self.architecture == 'topk':
            kth = mx.topk(act, self.k, axis=-1).min(axis=-1, keepdims=True)
            return mx.where(act >= kth, act, 0)
        if self.architecture == 'batchtopk':
            return mx.where(act > self.threshold, act, 0)
        return act

    def decode(self, f):
        return (f @ self.W_dec + self.b_dec) * self.scale

    def __call__(self, x):
        return self.decode(self.encode(x)).astype(x.dtype)


def load_sae(job_folder, seed=None):
    import mlx.core as mx
    folder = Path(job_folder)
    meta = json.loads((folder / 'sae.json').read_text())
    name = f"sae-seed{seed if seed is not None else meta['seeds'][0]}.safetensors"
    if not (folder / name).exists(): raise ValueError(f'The SAE job has no {name}')
    seed_meta = dict(meta, **meta['per_seed'][str(seed if seed is not None else meta['seeds'][0])])
    return SAE(mx.load(str(folder / name)), seed_meta)


class Activations:
    """The hook's activations for corpus windows, in a shuffled buffer."""

    def __init__(self, model, captured, layer, windows, buffer_tokens, pad, seed):
        import numpy as np
        self.model, self.captured, self.layer, self.windows = model, captured, layer, windows
        self.buffer_tokens, self.pad = buffer_tokens, pad
        self.rng = np.random.default_rng(seed)
        self.exhausted = False

    def fill(self, rows=16):
        import mlx.core as mx
        import numpy as np
        chunks, have = [], 0
        while have < self.buffer_tokens:
            batch = [w for w in (next(self.windows, None) for _ in range(rows)) if w is not None]
            if not batch: self.exhausted = True; break
            L = max(len(w['ids']) for w in batch)
            ids = np.full((len(batch), L), self.pad, 'int32'); valid = np.zeros((len(batch), L), bool)
            for i, w in enumerate(batch): ids[i, :len(w['ids'])] = w['ids']; valid[i, :len(w['ids'])] = True
            self.captured.clear()
            self.model(mx.array(ids))
            values = self.captured[self.layer].reshape(len(batch) * L, -1)
            values = values[mx.array(np.flatnonzero(valid.reshape(-1)))].astype(mx.float32)
            mx.eval(values)
            chunks.append(values); have += values.shape[0]
        if not chunks: return None
        data = mx.concatenate(chunks, axis=0)
        return data[mx.array(self.rng.permutation(data.shape[0]))]


def _ce(logits, ids, valid):
    """Mean next-token cross-entropy over valid positions."""
    import mlx.core as mx
    import numpy as np
    logp = logits[:, :-1].astype(mx.float32) - mx.logsumexp(logits[:, :-1].astype(mx.float32), axis=-1, keepdims=True)
    target = mx.array(ids[:, 1:])
    picked = mx.take_along_axis(logp, target[..., None], axis=-1)[..., 0]
    mask = mx.array((valid[:, 1:] & valid[:, :-1]).astype('float32'))
    return float((-(picked * mask).sum()).item()), float(mask.sum().item())


def train_one(c, seed, model, captured, layer, windows_factory, pad, progress, fraction_offset, fraction_span):
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    import numpy as np
    mx.random.seed(seed)
    rng = np.random.default_rng(seed)
    stream = Activations(model, captured, layer, windows_factory('train'), c['buffer_tokens'], pad, seed)
    first = stream.fill()
    if first is None: raise ValueError('The corpus gave no training text')
    d = int(first.shape[1])
    m = int(c.get('width') or c['expansion'] * d)
    memory = 4 * 6 * m * d  # weights, gradients and Adam moments
    total = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
    if memory > 0.5 * total: raise ValueError(f'An SAE of width {m} on {d} values needs about {memory / 1e9:.1f} GB; this Mac has {total / 1e9:.0f} GB')
    scale = float(mx.sqrt(mx.mean(mx.sum(first * first, axis=1)) / d).item()) or 1.0
    k = min(c['k'], m)
    lr = c['learning_rate'] or 2e-4 / math.sqrt(m / 16384)
    W_dec = mx.random.normal((m, d)); W_dec = W_dec / mx.linalg.norm(W_dec, axis=1, keepdims=True)
    params = dict(W_enc=W_dec.T * 1.0, b_enc=mx.zeros((m,)), W_dec=W_dec, b_dec=mx.mean(first / scale, axis=0))
    steps = max(1, c['tokens'] // c['batch'])
    warmup, decay_start = min(c['warmup_steps'], steps // 10), int(steps * (1 - c['decay_fraction']))
    schedule = lambda step: lr * min(1.0, (step + 1) / max(warmup, 1)) * (1.0 if step < decay_start else max(0.0, (steps - step) / max(steps - decay_start, 1)))
    optimizer = optim.Adam(learning_rate=lr)
    optimizer.init(params)
    last_fired = mx.zeros((m,), dtype=mx.int32)
    dead_steps = max(1, c['dead_tokens'] // c['batch'])
    architecture = c['architecture']
    threshold = [0.0]

    def encode_train(p, x):
        pre = (x - p['b_dec']) @ p['W_enc'] + p['b_enc']
        act = nn.relu(pre)
        if architecture == 'topk':
            kth = mx.stop_gradient(mx.topk(act, k, axis=-1).min(axis=-1, keepdims=True))
            f = mx.where(act >= kth, act, 0)
        elif architecture == 'batchtopk':
            flat = act.reshape(-1)
            kth = mx.stop_gradient(mx.topk(flat, k * x.shape[0]).min())
            f = mx.where(act >= kth, act, 0)
        else:
            f = act
        return pre, f

    def loss_fn(p, x, dead):
        pre, f = encode_train(p, x)
        recon = f @ p['W_dec'] + p['b_dec']
        error = x - recon
        mse = mx.mean(mx.sum(error * error, axis=1))
        total_loss = mse
        if architecture == 'relu':
            total_loss = total_loss + c['l1'] * mx.mean(mx.sum(f * mx.linalg.norm(p['W_dec'], axis=1), axis=1)) / d
        elif c['aux_k'] and c['aux_coefficient']:
            # Dead features try to explain what the live ones missed.
            dead_pre = mx.where(dead[None, :], nn.relu(pre), 0)
            kk = min(c['aux_k'], m)
            kth = mx.stop_gradient(mx.topk(dead_pre, kk, axis=-1).min(axis=-1, keepdims=True))
            aux_f = mx.where(mx.logical_and(dead_pre >= kth, dead_pre > 0), dead_pre, 0)
            aux_error = mx.stop_gradient(error) - aux_f @ p['W_dec']
            aux = mx.mean(mx.sum(aux_error * aux_error, axis=1)) / mx.maximum(mx.mean(mx.sum(mx.stop_gradient(error) ** 2, axis=1)), 1e-6)
            total_loss = total_loss + c['aux_coefficient'] * aux * mx.stop_gradient(mse) * mx.array(float(mx.any(dead).item()))
        return total_loss, (mse, f)

    grad_fn = mx.value_and_grad(lambda p, x, dead: loss_fn(p, x, dead)[0])
    losses, buffer, cursor, step, started = [], first / scale, 0, 0, time.time()
    while step < steps:
        if cursor + c['batch'] > buffer.shape[0]:
            refill = stream.fill()
            if refill is None: break
            buffer, cursor = refill / scale, 0
        x = buffer[cursor:cursor + c['batch']]; cursor += c['batch']
        dead = (step - last_fired) > dead_steps
        optimizer.learning_rate = schedule(step)
        loss, grads = grad_fn(params, x, dead)
        params = optimizer.apply_gradients(grads, params)
        params['W_dec'] = params['W_dec'] / mx.maximum(mx.linalg.norm(params['W_dec'], axis=1, keepdims=True), 1e-8)
        _, f = encode_train(params, x)
        fired = mx.any(f > 0, axis=0)
        last_fired = mx.where(fired, step, last_fired)
        if architecture == 'batchtopk':
            positive = mx.where(f > 0, f, mx.inf)
            threshold[0] = 0.99 * threshold[0] + 0.01 * float(mx.min(positive).item()) if step else float(mx.min(positive).item())
        mx.eval(params, optimizer.state, last_fired, loss)
        if step % 100 == 0 or step == steps - 1:
            losses.append(dict(step=step, loss=round(float(loss.item()), 6), dead_fraction=round(float(mx.mean(dead).item()), 4),
                               l0=round(float(mx.mean(mx.sum(f > 0, axis=1)).item()), 2), learning_rate=schedule(step)))
            progress(f'SAE seed {seed}: step {step:,} of {steps:,} (loss {float(loss.item()):.4f})',
                     fraction_offset + fraction_span * 0.8 * step / steps)
        step += 1
    meta = dict(scale=scale, architecture=architecture, k=k, threshold=threshold[0] if architecture == 'batchtopk' else None,
                width=m, width_in=d, steps=step, tokens=step * c['batch'], learning_rate=lr, seconds=time.time() - started)
    return SAE(params, meta), losses, int(mx.sum((step - last_fired) > dead_steps).item())


def evaluate(c, sae, model, captured, active, layer, windows, pad, align):
    """Held-out metrics, and (if align) the statistics for the neuron alignment."""
    import mlx.core as mx
    import numpy as np
    stats = dict(err=0.0, var=0.0, l0=0.0, n=0, fired=np.zeros(sae.width, bool))
    sums = dict(x=None, xx=None, ce=dict(clean=[0.0, 0.0], spliced=[0.0, 0.0], zero=[0.0, 0.0]))
    if align:
        d, m = sae.width_in, sae.width
        acc = dict(F=mx.zeros((m,)), FF=mx.zeros((m,)), A=mx.zeros((d,)), AA=mx.zeros((d, d)), FA=mx.zeros((m, d)))
    first_mean = None
    seen = 0
    while seen < c['eval_tokens']:
        batch = [w for w in (next(windows, None) for _ in range(8)) if w is not None]
        if not batch: break
        L = max(len(w['ids']) for w in batch)
        ids = np.full((len(batch), L), pad, 'int32'); valid = np.zeros((len(batch), L), bool)
        for i, w in enumerate(batch): ids[i, :len(w['ids'])] = w['ids']; valid[i, :len(w['ids'])] = True
        active.pop(layer, None); captured.clear()
        logits = model(mx.array(ids))
        x = captured[layer].reshape(len(batch) * L, -1)[mx.array(np.flatnonzero(valid.reshape(-1)))].astype(mx.float32)
        for name, value in zip(('clean',), (_ce(logits, ids, valid),)): sums['ce'][name][0] += value[0]; sums['ce'][name][1] += value[1]
        f = sae.encode(x)
        recon = sae.decode(f)
        if first_mean is None: first_mean = mx.mean(x, axis=0)
        stats['err'] += float(mx.sum((x - recon) ** 2).item())
        stats['var'] += float(mx.sum((x - first_mean) ** 2).item())
        stats['l0'] += float(mx.sum(f > 0).item()); stats['n'] += x.shape[0]
        stats['fired'] |= np.array(mx.any(f > 0, axis=0))
        if align:
            acc['F'] += f.sum(0); acc['FF'] += (f * f).sum(0); acc['A'] += x.sum(0); acc['AA'] += x.T @ x; acc['FA'] += f.T @ x
            mx.eval(acc)
        for name, change in (('spliced', lambda h: sae(h)), ('zero', lambda h: h * 0)):
            active[layer] = change
            value = _ce(model(mx.array(ids)), ids, valid)
            sums['ce'][name][0] += value[0]; sums['ce'][name][1] += value[1]
        active.pop(layer, None)
        seen += int(valid.sum())
    ce = {k: v[0] / max(v[1], 1) for k, v in sums['ce'].items()}
    recovered = (ce['zero'] - ce['spliced']) / (ce['zero'] - ce['clean']) if ce['zero'] != ce['clean'] else None
    metrics = dict(heldout_tokens=stats['n'], fvu=stats['err'] / max(stats['var'], 1e-12), l0=stats['l0'] / max(stats['n'], 1),
                   dead_on_heldout=float(1 - stats['fired'].mean()), ce_clean=ce['clean'], ce_spliced=ce['spliced'], ce_zero_ablation=ce['zero'],
                   ce_loss_recovered=recovered)
    return metrics, (acc if align else None)


def alignment(c, sae, acc):
    """Feature-to-neuron alignment from held-out sufficient statistics."""
    import mlx.core as mx
    import numpy as np
    n = c['_eval_n']
    F, FF, A, AA, FA = (np.array(acc[k]).astype('float64') for k in ('F', 'FF', 'A', 'AA', 'FA'))
    mf, ma = F / n, A / n
    var_f = np.maximum(FF / n - mf ** 2, 0); var_a = np.maximum(np.diag(AA) / n - ma ** 2, 0)
    cov_fa = FA / n - np.outer(mf, ma)
    cov_aa = AA / n - np.outer(ma, ma)
    corr = cov_fa / np.maximum(np.sqrt(np.outer(var_f, var_a)), 1e-12)
    W = np.array(sae.W_dec).astype('float64')
    share = W ** 2 / np.maximum((W ** 2).sum(1, keepdims=True), 1e-12)
    features, inverse = [], {}
    for j in range(sae.width):
        if var_f[j] <= 1e-12:
            features.append(dict(feature=j, live=False)); continue
        order = np.argsort(-np.abs(corr[j]))[:5]
        S = order
        cvec = cov_fa[j, S]
        try:
            beta = np.linalg.solve(cov_aa[np.ix_(S, S)] + 1e-9 * np.eye(len(S)), cvec)
            r2_5 = float(cvec @ beta / var_f[j])
        except np.linalg.LinAlgError:
            r2_5 = None
        shares = np.sort(share[j])[::-1]
        row = dict(feature=j, live=True, best_neuron=int(order[0]), best_correlation=round(float(corr[j, order[0]]), 4),
                   r2_1=round(float(corr[j, order[0]] ** 2), 4), r2_5=round(min(max(r2_5, 0.0), 1.0), 4) if r2_5 is not None else None,
                   top_neurons=[dict(neuron=int(i), correlation=round(float(corr[j, i]), 4)) for i in order],
                   decoder_share_top1=round(float(shares[0]), 4), decoder_share_top5=round(float(shares[:5].sum()), 4))
        row['candidate_new_building_block'] = bool(abs(row['best_correlation']) < c['corr_threshold'] and (row['r2_5'] or 0) < c['r2_threshold'])
        features.append(row)
        for i in order: inverse.setdefault(int(i), []).append(dict(feature=j, correlation=round(float(corr[j, i]), 4)))
    live = [f for f in features if f['live']]
    hist = lambda values, bins: np.histogram(values, bins=bins, range=(0, 1))[0].tolist()
    summary = dict(live_features=len(live), thresholds=dict(correlation=c['corr_threshold'], r2_5=c['r2_threshold']),
                   candidate_new_building_blocks=sum(f['candidate_new_building_block'] for f in live),
                   candidate_share=sum(f['candidate_new_building_block'] for f in live) / max(len(live), 1),
                   median_best_correlation=float(np.median([abs(f['best_correlation']) for f in live])) if live else None,
                   median_r2_5=float(np.median([f['r2_5'] or 0 for f in live])) if live else None,
                   best_correlation_histogram=hist([abs(f['best_correlation']) for f in live], 20),
                   r2_5_histogram=hist([f['r2_5'] or 0 for f in live], 20),
                   decoder_share_top1_histogram=hist([f['decoder_share_top1'] for f in live], 20))
    neurons = [dict(neuron=i, features=sorted(v, key=lambda e: -abs(e['correlation']))[:20]) for i, v in sorted(inverse.items())]
    return dict(summary=summary, features=features, neurons=neurons)


def run(config, folder, load_model, progress):
    import mlx.core as mx
    import numpy as np
    from . import corpus as corpora
    c = validate(config)
    folder = Path(folder)
    layer = c['layers'][0]
    model, tokenizer, model_config, captured, collecting, info = load_model(c['hook'], [layer])
    active = load_model.state['active']
    progress('Preparing the corpus', 0.0)
    docs, corpus_provenance = corpora.documents(c['corpus'], c['tokens'] + c['eval_tokens'] * 3, c['lab_root'], c.get('seed', 0),
                                               c['heldout_fraction'], progress=lambda m: progress(m, 0.0))
    train_docs = [d for d in docs if not d['heldout']]
    held_docs = [d for d in docs if d['heldout']]
    if not held_docs: raise ValueError('No held-out documents for evaluation: raise heldout_fraction or the corpus size')
    pad = getattr(tokenizer, 'pad_token_id', None) or 0

    def windows_factory(split):
        source = train_docs if split == 'train' else held_docs
        # Each source's share applies within the split.
        return corpora.contexts(source, tokenizer, c['context'], c['tokens'] if split == 'train' else c['eval_tokens'])

    align = c['alignment'] and c['hook'] == 'mlp_hidden'
    reports, per_seed = [], {}
    for n, seed in enumerate(c['seeds']):
        span = 1 / len(c['seeds'])
        sae, losses, dead = train_one(c, seed, model, captured, layer, windows_factory, pad, progress, n * span, span)
        mx.save_safetensors(str(folder / f'sae-seed{seed}.safetensors'), dict(W_enc=sae.W_enc, b_enc=sae.b_enc, W_dec=sae.W_dec, b_dec=sae.b_dec))
        progress(f'SAE seed {seed}: evaluating on held-out text', n * span + 0.85 * span)
        metrics, acc = evaluate(c, sae, model, captured, active, layer, windows_factory('heldout'), pad, align and n == 0)
        metrics.update(dead_in_training=dead / sae.width, seed=seed)
        per_seed[str(seed)] = {k: sae.meta[k] for k in ('scale', 'threshold', 'steps', 'tokens', 'learning_rate', 'seconds')}
        reports.append(dict(metrics, losses=losses, **{k: sae.meta[k] for k in ('width', 'width_in', 'k', 'architecture', 'steps', 'tokens')}))
        if acc is not None:
            c['_eval_n'] = metrics['heldout_tokens']
            progress('Aligning SAE features with neurons', n * span + 0.95 * span)
            aligned = alignment(c, sae, acc)
            (folder / 'sae-alignment.json').write_text(json.dumps(aligned, separators=(',', ':')))
            reports[-1]['alignment'] = aligned['summary']
    meta = dict(model=c['model'], revision=c.get('revision'), hook=c['hook'], layer=layer, architecture=c['architecture'],
                k=reports[0]['k'], width=reports[0]['width'], width_in=reports[0]['width_in'], seeds=c['seeds'], per_seed=per_seed,
                corpus=corpus_provenance)
    (folder / 'sae.json').write_text(json.dumps(meta, indent=2))
    spread = {}
    if len(reports) > 1:
        for key in ('fvu', 'l0', 'ce_loss_recovered', 'dead_on_heldout'):
            values = [r[key] for r in reports if r.get(key) is not None]
            spread[key] = dict(mean=float(np.mean(values)), min=float(np.min(values)), max=float(np.max(values)))
    return dict(reports=reports, seed_spread=spread, sae=meta, hook=info,
                note='CE loss recovered: 0 is as bad as zeroing the hook, 1 as good as the original. Alignment uses held-out tokens; '
                     'a candidate new building block has no neuron correlating above the threshold and no 5-neuron fit above the R^2 threshold.')
