"""Run a corpus through a model and record token-level activations at a hook, for every token.

Two stores, chosen with `store`:

- `reservoir` (default): per unit and per pole (positive, negative), the strongest examples with a window of tokens and
  the unit's activation on each, samples stratified by activation level, uniform random samples, a histogram and
  summary statistics. Held-out documents get their own strongest examples and random samples, for scoring labels on
  text the labeler never saw. A few hundred MB for 3,072 units, however many tokens.
- `raw`: every activation, fp16, in shards with token ids and positions, up to a disk budget (for training SAEs from a
  fixed set of activations).

Units are the hook's coordinates (neurons), random unit directions in the same space (the baseline for auto-interp),
and SAE features (from an SAE job), all treated the same way.

The capture checkpoints as it goes; a new capture with `resume_from` continues where an interrupted one stopped.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import time
from pathlib import Path

# Activation-level buckets for stratified samples and the histogram: |value| in half-decade bins from 0.01 to 1000.
EDGES = [10 ** (e / 2) for e in range(-4, 7)]   # 0.01 ... 1000: 11 edges, 12 bins (below 0.01 is bin 0)
BINS = len(EDGES) + 1
# How often each pole reaches each level, in 1/8-decade steps from 0.01 to 1000: rates at a fraction of the maximum
# are interpolated from these.
LEVELS = [10 ** (e / 8) for e in range(-16, 25)]
POLES = ('positive', 'negative')


def bin_of(values, xp):
    """The histogram bin of each |value| (0 = below 0.01)."""
    magnitude = xp.abs(values)
    out = xp.zeros(values.shape, dtype=xp.int32)
    for edge in EDGES:
        out = out + (magnitude >= edge).astype(xp.int32)
    return out


def defaults(config):
    c = dict(hook='mlp_hidden', context=1024, tokens=2_000_000, heldout_fraction=0.2, top_k=40, heldout_top_k=20,
             bucket_samples=6, random_samples=40, heldout_random=40, window_before=32, window_after=8,
             batch_tokens=16384, store='reservoir', disk_budget_gb=20.0, units={'neurons': 'all'}, checkpoint_seconds=120)
    c.update({k: v for k, v in config.items() if v is not None})
    return c


def validate(config):
    c = defaults(config)
    from .hooks import HOOKS
    if c['hook'] not in HOOKS: raise ValueError(f'hook must be one of {", ".join(HOOKS)}')
    checks = [('context', 16, 32768), ('tokens', 1000, 500_000_000), ('top_k', 1, 200), ('heldout_top_k', 0, 200),
              ('bucket_samples', 0, 32), ('random_samples', 0, 400), ('heldout_random', 0, 400), ('window_before', 0, 1024),
              ('window_after', 0, 256), ('batch_tokens', 256, 262144)]
    for key, low, high in checks:
        if type(c[key]) is not int or not low <= c[key] <= high: raise ValueError(f'{key} must be an integer between {low} and {high}')
    if type(c['heldout_fraction']) not in (int, float) or not 0 <= c['heldout_fraction'] < 1: raise ValueError('heldout_fraction must be in [0, 1)')
    if c['store'] not in ('reservoir', 'raw', 'both'): raise ValueError('store must be reservoir, raw or both')
    if type(c['checkpoint_seconds']) not in (int, float) or not 0 <= c['checkpoint_seconds'] <= 86400: raise ValueError('checkpoint_seconds: 0–86400')
    if type(c['disk_budget_gb']) not in (int, float) or not 0.01 <= c['disk_budget_gb'] <= 4000: raise ValueError('disk_budget_gb out of range')
    units = c['units']
    if not isinstance(units, dict): raise ValueError('units: {"neurons": "all" | count | [indices], "random_directions": count, "sae": job id}')
    n = units.get('neurons', 'all')
    if not (n == 'all' or n is None or (type(n) is int and n >= 0) or (isinstance(n, list) and all(type(i) is int and i >= 0 for i in n))):
        raise ValueError('units.neurons: "all", a count to sample, or a list of indices')
    if type(units.get('random_directions', 0)) is not int or not 0 <= units.get('random_directions', 0) <= 10000:
        raise ValueError('units.random_directions: 0–10000')
    return c


class Units:
    """Maps a hook's activations [T, width] to unit activations [T, units]: chosen neurons, random directions, SAE features."""

    def __init__(self, spec, width, seed, sae=None):
        import numpy as np
        rng = np.random.default_rng(seed + 7919)
        n = spec.get('neurons', 'all')
        if n == 'all': neurons = list(range(width))
        elif n is None: neurons = []
        elif type(n) is int: neurons = sorted(rng.choice(width, size=min(n, width), replace=False).tolist())
        else: neurons = sorted(set(n))
        if any(i >= width for i in neurons): raise ValueError(f'Neuron indices must be below {width}')
        self.neurons = neurons
        count = spec.get('random_directions', 0)
        directions = rng.normal(size=(width, count)).astype('float32')
        directions /= np.maximum(np.linalg.norm(directions, axis=0, keepdims=True), 1e-12)
        self.directions = directions
        self.sae = sae
        self.labels = ([dict(kind='neuron', index=i) for i in neurons] + [dict(kind='random', index=j) for j in range(count)]
                       + ([dict(kind='sae', index=f) for f in range(sae.width)] if sae else []))

    def __len__(self): return len(self.labels)

    def __call__(self, values):
        import mlx.core as mx
        parts = []
        if self.neurons: parts.append(values[:, mx.array(self.neurons)] if len(self.neurons) != values.shape[1] else values)
        if self.directions.shape[1]: parts.append(values @ mx.array(self.directions))
        if self.sae: parts.append(self.sae.encode(values))
        return mx.concatenate(parts, axis=1) if len(parts) > 1 else parts[0]


class Reservoir:
    """Per-unit examples and statistics, updated batch by batch on the GPU."""

    def __init__(self, n, c, state=None):
        import numpy as np
        self.n, self.c = n, c
        self.width = c['window_before'] + 1 + c['window_after']
        if state is not None:
            self.s = {k: state[k] for k in state.files} if hasattr(state, 'files') else dict(state)
            return
        W = self.width
        s = {}
        def slot(name, k, initial):
            s[f'{name}_key'] = np.full((n, k), initial, 'float32')
            s[f'{name}_value'] = np.zeros((n, k), 'float32')
            s[f'{name}_ids'] = np.full((n, k, W), -1, 'int32')
            s[f'{name}_acts'] = np.zeros((n, k, W), 'float16')
            s[f'{name}_where'] = np.full((n, k, 2), -1, 'int64')   # (context number, position)
        for p in POLES:
            slot(f'top_{p}', c['top_k'], -np.inf)                    # key = pole value; keep the largest
            slot(f'heldout_top_{p}', c['heldout_top_k'], -np.inf)
            for b in range(BINS):
                slot(f'bucket_{p}_{b}', c['bucket_samples'], np.inf)  # key = random; keep the smallest
        slot('random', c['random_samples'], np.inf)
        slot('heldout_random', c['heldout_random'], np.inf)
        s['histogram'] = np.zeros((n, 2, BINS), 'int64')
        s['at_least'] = np.zeros((n, 2, len(LEVELS)), 'int64')
        s['maximum'] = np.zeros((n, 2), 'float32')
        s['sum'] = np.zeros(n, 'float64')
        s['sum_squares'] = np.zeros(n, 'float64')
        s['count'] = np.zeros(1, 'int64')
        s['heldout_count'] = np.zeros(1, 'int64')
        self.s = s

    def _merge(self, name, keys, largest, ids, acts, where, values):
        """Merge batch candidates (keys [n, k']) into a slot, keeping the k best keys."""
        import numpy as np
        s = self.s
        old = s[f'{name}_key']
        k = old.shape[1]
        if k == 0 or keys.shape[1] == 0: return
        combined = np.concatenate([old, keys], axis=1)
        order = np.argsort(-combined if largest else combined, axis=1, kind='stable')[:, :k]
        def pick(old_part, new_part):
            both = np.concatenate([old_part, new_part], axis=1)
            index = order.reshape(order.shape + (1,) * (both.ndim - 2))
            return np.take_along_axis(both, index, axis=1)
        s[f'{name}_key'] = pick(old, keys)
        s[f'{name}_value'] = pick(s[f'{name}_value'], values)
        s[f'{name}_ids'] = pick(s[f'{name}_ids'], ids)
        s[f'{name}_acts'] = pick(s[f'{name}_acts'], acts)
        s[f'{name}_where'] = pick(s[f'{name}_where'], where)

    def update(self, values, ids, valid, heldout, context_numbers, rng_seed):
        """values: mx [B, L, n] unit activations; ids: np [B, L]; valid: np [B, L] bool; heldout: np [B] bool."""
        import mlx.core as mx
        import numpy as np
        c, n = self.c, self.n
        B, L = ids.shape
        before, after = c['window_before'], c['window_after']
        values = values.astype(mx.float32)
        valid_mx = mx.array(valid)
        flat = values.reshape(B * L, n)
        # Windows: pad the sequence axis so every position has a full window.
        padded_ids = np.full((B, before + L + after), -1, 'int32')
        padded_ids[:, before:before + L] = np.where(valid, ids, -1)
        padded_values = mx.pad(values, [(0, 0), (before, after), (0, 0)])

        def windows(positions, units):
            """positions, units: np [n, k] flat token indices and unit indices -> ids/acts [n, k, W], where [n, k, 2]."""
            rows, cols = positions // L, positions % L
            offsets = np.arange(self.width)
            window_ids = padded_ids[rows[..., None], cols[..., None] + offsets]
            flat_index = (rows[..., None] * (before + L + after) + cols[..., None] + offsets) * n + units[..., None]
            window_acts = np.array(mx.take(padded_values.reshape(-1), mx.array(flat_index.reshape(-1))).reshape(flat_index.shape)).astype('float16')
            where = np.stack([context_numbers[rows], cols], axis=-1)
            return window_ids, window_acts, where

        unit_index = np.broadcast_to(np.arange(n)[:, None], (n, 1))
        token_heldout = mx.array(np.repeat(heldout, L))
        token_valid = valid_mx.reshape(-1)
        train_mask = mx.logical_and(token_valid, mx.logical_not(token_heldout))
        held_mask = mx.logical_and(token_valid, token_heldout)

        def best(keys, mask, k, largest):
            """The k best keys per unit among masked tokens: (keys np [n, k], positions np [n, k])."""
            k = min(k, keys.shape[0])
            if k == 0: return np.zeros((n, 0), 'float32'), np.zeros((n, 0), 'int64')
            fill = -mx.inf if largest else mx.inf
            masked = mx.where(mask[:, None], keys, fill)
            order = mx.argpartition(-masked if largest else masked, kth=k - 1, axis=0)[:k]          # [k, n]
            chosen = mx.take_along_axis(masked, order, axis=0)
            return np.array(chosen.T), np.array(order.T).astype('int64')

        def take(name, keys, positions, largest):
            ok = np.isfinite(keys)
            if not ok.any(): return
            keys = np.where(ok, keys, -np.inf if largest else np.inf)
            positions = np.where(ok, positions, 0)
            units = np.broadcast_to(unit_index, positions.shape)
            window_ids, window_acts, where = windows(positions, units)
            vals = np.array(mx.take(flat.reshape(-1), mx.array((positions * n + units).reshape(-1))).reshape(positions.shape))
            self._merge(name, keys.astype('float32'), largest, window_ids, window_acts, where, vals.astype('float32'))

        for sign, pole in ((1.0, 'positive'), (-1.0, 'negative')):
            pole_values = flat * sign
            take(f'top_{pole}', *best(pole_values, train_mask, c['top_k'], True), True)
            take(f'heldout_top_{pole}', *best(pole_values, held_mask, c['heldout_top_k'], True), True)
        key = mx.random.uniform(shape=flat.shape, key=mx.random.key(rng_seed))
        bins = bin_of(flat, mx)
        positive = flat > 0
        for p_index, pole in enumerate(POLES):
            on_pole = positive if pole == 'positive' else mx.logical_not(positive)
            for b in range(BINS):
                in_bin = mx.logical_and(mx.logical_and(on_pole, bins == b), train_mask[:, None])
                self.s['histogram'][:, p_index, b] += np.array(mx.sum(mx.logical_and(mx.logical_and(on_pole, bins == b), token_valid[:, None]), axis=0)).astype('int64')
                if c['bucket_samples']:
                    keys = mx.where(in_bin, key, mx.inf)
                    order = mx.argpartition(keys, kth=min(c['bucket_samples'], keys.shape[0]) - 1, axis=0)[:c['bucket_samples']]
                    chosen = mx.take_along_axis(keys, order, axis=0)
                    take(f'bucket_{pole}_{b}', np.array(chosen.T), np.array(order.T).astype('int64'), False)
        for p_index, sign in enumerate((1.0, -1.0)):
            pole_values = mx.where(token_valid[:, None], flat * sign, 0)
            counts = mx.stack([mx.sum(pole_values >= level, axis=0) for level in LEVELS], axis=1)
            self.s['at_least'][:, p_index, :] += np.array(counts).astype('int64')
        take('random', *best(key, train_mask, c['random_samples'], False), False)
        take('heldout_random', *best(key, held_mask, c['heldout_random'], False), False)
        masked = mx.where(token_valid[:, None], flat, 0)
        self.s['maximum'][:, 0] = np.maximum(self.s['maximum'][:, 0], np.array(mx.max(masked, axis=0)))
        self.s['maximum'][:, 1] = np.maximum(self.s['maximum'][:, 1], np.array(mx.max(-masked, axis=0)))
        self.s['sum'] += np.array(mx.sum(masked, axis=0)).astype('float64')
        self.s['sum_squares'] += np.array(mx.sum(masked * masked, axis=0)).astype('float64')
        self.s['count'][0] += int(valid.sum())
        self.s['heldout_count'][0] += int(valid[heldout].sum())

    def save(self, path):
        import numpy as np
        temporary = Path(str(path) + '.tmp.npz')
        np.savez(temporary, **self.s)
        temporary.replace(path)


class RawStore:
    """Every activation at the hook, fp16, in shards: activations [T, width], token ids, (context, position)."""

    def __init__(self, folder, layer, budget_bytes):
        self.folder, self.layer, self.budget = Path(folder), layer, budget_bytes
        self.folder.mkdir(parents=True, exist_ok=True)
        self.shard = len(list(self.folder.glob(f'layer-{layer}-*.safetensors')))
        self.full = False

    def used(self):
        return sum(p.stat().st_size for p in self.folder.glob('*.safetensors'))

    def write(self, values, ids, valid, context_numbers):
        import mlx.core as mx
        import numpy as np
        if self.full: return False
        B, L = ids.shape
        mask = valid.reshape(-1)
        flat = np.array(values.reshape(B * L, -1).astype(mx.float16))[mask]
        if self.used() + flat.nbytes > self.budget:
            self.full = True
            return False
        positions = np.stack([np.repeat(context_numbers, L), np.tile(np.arange(L), B)], axis=1)[mask]
        mx.save_safetensors(str(self.folder / f'layer-{self.layer}-{self.shard:05d}.safetensors'),
                            {'activations': mx.array(flat), 'token_ids': mx.array(ids.reshape(-1)[mask].astype('int32')),
                             'positions': mx.array(positions.astype('int32'))})
        self.shard += 1
        return True


def run(config, folder, load_model, progress):
    """The capture job. load_model(hook, layers) -> (model, tokenizer, model_config, captured, collecting, info)."""
    import mlx.core as mx
    import numpy as np
    from . import corpus as corpora
    c = validate(config)
    folder = Path(folder)
    layers = c.get('layers', [0])
    started = time.time()
    resume = None
    if c.get('resume_from'):
        previous = Path(c['lab_root']) / c['resume_from']
        if not (previous / 'capture-state.json').exists(): raise ValueError('resume_from: that job has no capture checkpoint')
        resume = json.loads((previous / 'capture-state.json').read_text())
        keys = ('model', 'hook', 'layers', 'corpus', 'tokens', 'context', 'seed', 'units', 'heldout_fraction', 'store', 'top_k',
                'window_before', 'window_after', 'bucket_samples', 'random_samples', 'heldout_top_k', 'heldout_random')
        if any(resume['config'].get(k) != c.get(k) for k in keys):
            raise ValueError('resume_from: the settings differ from the interrupted capture; resume with the same settings')
        for p in previous.iterdir():
            if p.name.startswith(('capture-layer-', 'raw')) or p.name == 'capture-state.json':
                (shutil.copytree if p.is_dir() else shutil.copy2)(p, folder / p.name)

    model, tokenizer, model_config, captured, collecting, info = load_model(c['hook'], layers)
    from .hooks import width as hook_width
    width = hook_width(model, c['hook'], layers[0])
    probe = mx.array([[tokenizer.encode('width')[0]]])
    if width is None:
        model(probe); width = int(captured[layers[0]].shape[-1])
    sae = None
    if (c['units'] or {}).get('sae'):
        from .sae import load_sae
        sae = load_sae(Path(c['lab_root']) / c['units']['sae'])
        if sae.width_in != width: raise ValueError(f'The SAE reads {sae.width_in} values; this hook has {width}')
    units = Units(c['units'], width, c.get('seed', 0), sae)
    if not len(units): raise ValueError('No units selected')

    progress('Preparing the corpus', 0.0)
    docs, corpus_provenance = corpora.documents(c['corpus'], c['tokens'], c['lab_root'], c.get('seed', 0), c['heldout_fraction'],
                                               progress=lambda m: progress(m, 0.0))
    if not docs: raise ValueError('The corpus has no text')
    reservoirs, raw = {}, {}
    for layer in layers:
        state_path = folder / f'capture-layer-{layer}.npz'
        if c['store'] in ('reservoir', 'both'):
            reservoirs[layer] = Reservoir(len(units), c, np.load(state_path) if resume and state_path.exists() else None)
        if c['store'] in ('raw', 'both'):
            raw[layer] = RawStore(folder / 'raw', layer, c['disk_budget_gb'] * 1e9 / len(layers))
    done_contexts = resume['contexts'] if resume else 0
    done_tokens = resume['tokens_done'] if resume else 0
    rows = max(1, c['batch_tokens'] // c['context'])
    stream = corpora.contexts(docs, tokenizer, c['context'], c['tokens'], c.get('stride'))
    for _ in range(done_contexts): next(stream, None)
    number, last_save, stopped = done_contexts, time.time(), None
    pad = getattr(tokenizer, 'pad_token_id', None) or 0

    def checkpoint():
        for layer, r in reservoirs.items(): r.save(folder / f'capture-layer-{layer}.npz')
        (folder / 'capture-state.json').write_text(json.dumps(dict(config={k: v for k, v in c.items() if k != 'lab_root'},
                                                                   contexts=number, tokens_done=done_tokens)))

    while True:
        batch = [x for x in (next(stream, None) for _ in range(rows)) if x is not None]
        if not batch: break
        L = max(len(x['ids']) for x in batch)
        ids = np.full((len(batch), L), pad, 'int32')
        valid = np.zeros((len(batch), L), bool)
        for i, x in enumerate(batch):
            ids[i, :len(x['ids'])] = x['ids']; valid[i, :len(x['ids'])] = True
        heldout = np.array([x['heldout'] for x in batch])
        numbers = np.arange(number, number + len(batch))
        captured.clear()
        model(mx.array(ids))
        for layer in layers:
            values = captured[layer]
            if layer in raw and not raw[layer].write(values, ids, valid, numbers) and c['store'] == 'raw':
                stopped = 'disk budget reached'
            if layer in reservoirs:
                B, T, _ = values.shape
                unit_values = units(values.reshape(B * T, -1)).reshape(B, T, -1)
                mx.eval(unit_values)
                reservoirs[layer].update(unit_values, ids, valid, heldout, numbers, (c.get('seed', 0) * 1_000_003 + number) % 2**31)
        number += len(batch)
        done_tokens += int(valid.sum())
        elapsed = time.time() - started
        progress(f'{done_tokens:,} of {c["tokens"]:,} tokens', min(1.0, done_tokens / c['tokens']))
        if time.time() - last_save >= c['checkpoint_seconds']:
            checkpoint(); last_save = time.time()
        if stopped: break
    checkpoint()

    manifest = dict(units=units.labels, layers=layers, hook=c['hook'], width=width, tokens=done_tokens, contexts=number,
                    edges=EDGES, levels=LEVELS, poles=POLES, window_before=c['window_before'], window_after=c['window_after'],
                    corpus=corpus_provenance, documents=[dict(id=d['id'], heldout=d['heldout']) for d in docs],
                    random_directions_seed=c.get('seed', 0) + 7919, stopped=stopped, hook_info=info)
    (folder / 'capture-manifest.json').write_text(json.dumps(manifest))
    if units.directions.shape[1]: np.save(folder / 'random-directions.npy', units.directions)
    by_layer = {}
    for layer, r in reservoirs.items():
        s = r.s
        count = max(int(s['count'][0]), 1)
        mean = s['sum'] / count
        by_layer[str(layer)] = dict(units=len(units), tokens=int(s['count'][0]), heldout_tokens=int(s['heldout_count'][0]),
                                    dead_units=int(np.sum(s['maximum'].max(1) < EDGES[0])),
                                    mean_std=float(np.mean(np.sqrt(np.maximum(s['sum_squares'] / count - mean ** 2, 0)))))
    return dict(capture=dict(tokens=done_tokens, contexts=number, layers=by_layer, units=len(units),
                             neurons=len(units.neurons), random_directions=int(units.directions.shape[1]),
                             sae_features=sae.width if sae else 0, store=c['store'], stopped=stopped,
                             raw_bytes=sum(p.stat().st_size for p in (folder / 'raw').glob('*')) if raw else 0,
                             seconds=time.time() - started, corpus=corpus_provenance),
                warnings=[f"Corpus source {p['hf']} ({p.get('config')}) was skipped: {p['skipped']}" for p in corpus_provenance if p.get('skipped')],
                hook=info, note='Token-level capture. Examples are kept per unit and per pole; held-out documents are kept apart for scoring.')
