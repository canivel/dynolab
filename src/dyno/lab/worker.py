"""One bounded experiment per process. No hooks touch a serving model."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
import time


def tap_layer(original, index, captured, active, collecting):
    import mlx.core as mx
    import mlx.nn as nn

    class Tap(nn.Module):
        def __init__(self, original, index):
            super().__init__()
            self.original = original
            object.__setattr__(self, '_index', index)

        def __getattr__(self, name):
            # Hybrid decoders consult block metadata (e.g. is_linear) before
            # calling it. Preserve the original block interface, not just call().
            try:
                return super().__getattr__(name)
            except AttributeError:
                original = super().__getattr__('original')
                return getattr(original, name)

        def __call__(self, *args, **kwargs):
            value = self.original(*args, **kwargs)
            if not isinstance(value, mx.array) or value.ndim != 3:
                raise ValueError('This model does not expose a supported [batch, token, hidden] block output')
            index = self._index
            if index in active:
                value = active[index](value)
            if collecting[0]:
                captured[index] = value
            return value

    return Tap(original, index)


def run(config, folder):
    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    from mlx_lm import load

    seed = config.get('seed', 0)
    mx.random.seed(seed)
    rng = np.random.default_rng(seed)
    started = time.time()
    model, tokenizer, model_config = load(config['model'], tokenizer_config={'trust_remote_code': False}, return_config=True, revision=config.get('revision'))
    model_path = Path(getattr(tokenizer, 'name_or_path', config['model']))
    manifest = [dict(name=p.name, bytes=p.stat().st_size, modified_ns=p.stat().st_mtime_ns) for p in sorted(model_path.glob('*.safetensors'))] if model_path.is_dir() else []
    layers = model.layers
    selected = config.get('layers', [0])
    if any(i >= len(layers) for i in selected):
        raise ValueError(f'Model has {len(layers)} layers; requested {selected}')
    limit = config.get('max_input_tokens', 256)
    captured = {}
    active = {}
    collecting = [True]

    for index in selected:
        layers[index] = tap_layer(layers[index], index, captured, active, collecting)

    def encode(text):
        if not isinstance(text, str) or not text.strip():
            raise ValueError('Prompt/examples must be nonempty text')
        ids = tokenizer.encode(text)
        if not 1 <= len(ids) <= limit:
            raise ValueError(f'Input has {len(ids)} tokens; configured limit is {limit}. Inputs are not silently truncated.')
        return ids

    def forward(ids):
        captured.clear()
        logits = model(mx.array([ids]))
        mx.eval(logits, *captured.values())
        return logits

    def vector(text, layer):
        forward(encode(text))
        return np.array(captured[layer][0, -1].astype(mx.float32))

    def top(logits, count=5):
        probs = np.array(mx.softmax(logits.astype(mx.float32)))
        ids = np.argsort(probs)[-count:][::-1]
        return [dict(token_id=int(i), token=tokenizer.decode([int(i)]), probability=float(probs[i])) for i in ids]

    def generate(ids):
        generated = []
        collecting[0] = False
        try:
            for _ in range(config.get('max_tokens', 32)):
                logits = model(mx.array([ids + generated]))
                token = int(mx.argmax(logits[0, -1]).item())
                if token in getattr(tokenizer, 'eos_token_ids', {tokenizer.eos_token_id}):
                    break
                generated.append(token)
            return tokenizer.decode(generated)
        finally:
            collecting[0] = True

    operation = config['operation']
    result = {}
    if operation == 'patch_sweep':
        from .patching import sweep
        result = sweep(config, selected, encode, forward, captured, active, tokenizer)
    elif operation in ('inspect', 'compare'):
        ids = encode(config.get('prompt', ''))
        baseline = forward(ids)
        baseline_captures = {i: captured[i] for i in selected}
        if operation == 'inspect':
            maps = []
            for index in selected:
                states = baseline_captures[index][0]
                norms = np.array(mx.linalg.norm(states.astype(mx.float32), axis=-1))
                entry = dict(layer=index, norms=norms.tolist())
                # A raw logit lens is available only with the matching final norm/head.
                language_model = getattr(model, 'language_model', model)
                core = getattr(language_model, 'model', None)
                if core is not None and hasattr(core, 'norm'):
                    normalized = core.norm(states)
                    if hasattr(language_model, 'lm_head'):
                        lens = language_model.lm_head(normalized)
                    elif hasattr(core, 'embed_tokens'):
                        lens = core.embed_tokens.as_linear(normalized)
                    else:
                        lens = None
                    if lens is not None:
                        entry['predictions'] = [top(lens[pos], 3) for pos in range(len(ids))]
                maps.append(entry)
            mx.savez(str(folder / 'activations.npz'), **{f'layer_{i}': h for i, h in baseline_captures.items()})
            result = dict(tokens=[tokenizer.decode([i]) for i in ids], token_ids=ids,
                          layers=maps, next_tokens=top(baseline[0, -1]),
                          note='Raw block-output logit lens; an intermediate readout is not a causal explanation.')
        else:
            layer = selected[0]
            kind = config.get('intervention', 'scale')
            strengths = config.get('strengths', [0.0, 0.5, 1.0, 1.5])
            if not isinstance(strengths, list) or not 1 <= len(strengths) <= 9 or any(type(s) not in (int, float) or not np.isfinite(s) or abs(s) > 5 for s in strengths):
                raise ValueError('Use 1–9 finite strengths between -5 and 5')
            if kind not in ('scale', 'ablate', 'steer', 'patch'):
                raise ValueError('intervention must be scale, ablate, steer or patch')
            direction = None
            if kind == 'steer':
                direction = vector(config.get('positive', ''), layer) - vector(config.get('negative', ''), layer)
                direction /= max(float(np.linalg.norm(direction)), 1e-8)
            elif kind == 'patch':
                direction = vector(config.get('donor_prompt', ''), layer)
            prompts = config.get('prompts', [config['prompt']])
            if not isinstance(prompts, list) or not 1 <= len(prompts) <= 32:
                raise ValueError('Use 1–32 comparison prompts')
            trials = []
            for prompt in prompts:
                ids = encode(prompt)
                active.clear()
                original = forward(ids)
                probs = mx.softmax(original[0, -1].astype(mx.float32))
                target_text = config.get('target_token')
                if target_text:
                    target_ids = tokenizer.encode(target_text, add_special_tokens=False)
                    if len(target_ids) != 1:
                        raise ValueError('target_token must encode to exactly one token; include leading space if needed')
                    target = target_ids[0]
                else:
                    target = int(mx.argmax(probs).item())
                reference = float(probs[target].item())
                base_output = generate(ids)
                for strength in strengths:
                    def intervention(h, strength=float(strength)):
                        # Intervene only at the final position, on every forward pass.
                        last = h[:, -1:, :]
                        if kind == 'scale':
                            changed = last * strength
                        elif kind == 'ablate':
                            changed = last * (1 - strength)
                        elif kind == 'patch':
                            changed = last * (1 - strength) + mx.array(direction)[None, None, :] * strength
                        else:
                            changed = last + mx.array(direction)[None, None, :] * strength
                        return mx.concatenate([h[:, :-1, :], changed], axis=1)
                    active[layer] = intervention
                    changed = forward(ids)
                    probability = float(mx.softmax(changed[0, -1].astype(mx.float32))[target].item())
                    trials.append(dict(prompt=prompt, strength=strength, layer=layer,
                                       target_token=tokenizer.decode([target]), baseline_probability=reference,
                                       probability=probability, delta=probability-reference,
                                       baseline=base_output, output=generate(ids)))
                active.clear()
            result = dict(trials=trials, intervention=kind, position='last token, each forward pass',
                          note='Probability comparisons use an identical prefix. Generated continuations are free-running and may diverge. Greedy decoding.')
    elif operation in ('probe', 'sae'):
        examples = config.get('examples', [])
        if not isinstance(examples, list) or len(examples) < 8:
            raise ValueError('Provide at least 8 examples with text and explicit train/test split')
        if any(not isinstance(e, dict) or e.get('split') not in ('train', 'test') for e in examples):
            raise ValueError('Every example needs text and split: train or test')
        train_mask = np.array([e['split'] == 'train' for e in examples])
        if sum(train_mask) < 4 or sum(~train_mask) < 4:
            raise ValueError('Need at least 4 training and 4 held-out examples')
        train_text = {e['text'].strip() for e in examples if e['split'] == 'train'}
        if any(e['text'].strip() in train_text for e in examples if e['split'] == 'test'):
            raise ValueError('Identical text appears in training and test sets')
        reports = []
        for layer in selected:
            x = np.stack([vector(e['text'], layer) for e in examples])
            if operation == 'probe':
                if any(type(e.get('label')) is not int or e['label'] not in (0, 1) for e in examples):
                    raise ValueError('Probe labels must be 0 or 1')
                y = np.array([e['label'] for e in examples])
                if len(set(y[train_mask])) != 2 or len(set(y[~train_mask])) != 2:
                    raise ValueError('Both splits need positive and negative examples')
                mean, std = x[train_mask].mean(0), x[train_mask].std(0).clip(.01)
                z = (x - mean) / std
                def fit(labels):
                    w = np.zeros(z.shape[1]); b = 0.
                    rate = .1 / max(1., np.linalg.norm(z[train_mask], ord=2)**2 / len(labels))
                    for _ in range(300):
                        p = 1 / (1 + np.exp(-np.clip(z[train_mask] @ w + b, -30, 30)))
                        error = p - labels
                        w -= rate * (z[train_mask].T @ error / len(labels) + .01*w)
                        b -= rate * error.mean()
                    return w, b
                w, b = fit(y[train_mask]); random_w, random_b = fit(rng.permutation(y[train_mask]))
                scores = 1 / (1 + np.exp(-np.clip(z @ w + b, -30, 30)))
                truth, prediction = y[~train_mask], scores[~train_mask]
                positive, negative = prediction[truth==1], prediction[truth==0]
                auc = np.mean((positive[:,None] > negative) + .5*(positive[:,None] == negative))
                control = 1/(1+np.exp(-np.clip(z[~train_mask]@random_w+random_b,-30,30)))
                np.savez(folder / f'probe-layer-{layer}.npz', weight=w, bias=b, mean=mean, std=std)
                reports.append(dict(layer=layer, accuracy=float(np.mean((prediction>=.5)==truth)),
                                    auc=float(auc), brier=float(np.mean((prediction-truth)**2)),
                                    shuffled_label_accuracy=float(np.mean((control>=.5)==truth)),
                                    majority_accuracy=float(np.mean(truth == (y[train_mask].mean()>=.5))),
                                    scores=[dict(text=e['text'], split=e['split'], label=e['label'], score=float(s)) for e,s in zip(examples,scores)]))
            else:
                import mlx.optimizers as optim
                width = config.get('features', 64)
                steps = config.get('steps', 100)
                if type(width) is not int or not 8 <= width <= 512 or type(steps) is not int or not 1 <= steps <= 500:
                    raise ValueError('SAE features: 8–512; steps: 1–500')
                architecture = config.get('sae_architecture', 'relu')
                k = config.get('top_k', min(8, width))
                if architecture not in ('relu', 'topk') or type(k) is not int or not 1 <= k <= width:
                    raise ValueError('SAE architecture must be relu/topk; top_k must be between 1 and features')
                mean = x[train_mask].mean(0)
                scale = max(float(np.sqrt(np.mean((x[train_mask]-mean)**2))), 1e-6)
                train = mx.array((x[train_mask]-mean)/scale)
                test = mx.array((x[~train_mask]-mean)/scale)
                class SAE(nn.Module):
                    def __init__(self):
                        super().__init__()
                        self.encoder=nn.Linear(x.shape[1],width)
                        self.decoder=nn.Linear(width,x.shape[1])
                    def __call__(self,h):
                        f=nn.relu(self.encoder(h))
                        if architecture == 'topk':
                            rank = mx.argsort(mx.argsort(f, axis=-1), axis=-1)
                            f = mx.where(rank >= width-k, f, 0)
                        return self.decoder(f),f
                sae=SAE(); optimizer=optim.Adam(learning_rate=.001)
                def loss(net,h):
                    recovered,f=net(h)
                    return mx.mean((recovered-h)**2)+(0 if architecture == 'topk' else .001*mx.mean(f))
                grad=nn.value_and_grad(sae,loss)
                losses=[]
                for step in range(steps):
                    value,grads=grad(sae,train);optimizer.update(sae,grads)
                    mx.eval(sae.parameters(),optimizer.state,value)
                    if step % 10==0 or step==steps-1: losses.append(dict(step=step,loss=float(value.item())))
                reconstructed,features=sae(test)
                error=float(mx.mean((reconstructed-test)**2).item())
                sae.save_weights(str(folder/f'sae-layer-{layer}.safetensors'))
                np.savez(folder/f'sae-normalization-{layer}.npz',mean=mean,scale=scale)
                f=np.array(features)
                ranked=np.argsort(f.mean(0))[-min(width,16):][::-1]
                test_examples=[e for e in examples if e['split']=='test']
                reports.append(dict(layer=layer, architecture=architecture, top_k=k if architecture == "topk" else None, held_out_mse=error, mean_active=float((f>0).sum(1).mean()),
                                    dead_fraction=float(np.mean(np.all(f==0,axis=0))), losses=losses,
                                    features=[dict(feature=int(i), mean=float(f[:,i].mean()), examples=[dict(text=test_examples[j]['text'], activation=float(f[j,i])) for j in np.argsort(f[:,i])[-3:][::-1]]) for i in ranked]))
        result=dict(reports=reports, pooling='last input token', note=('Logistic probe; held-out labels never used for fitting. A score is not evidence of causal use.' if operation=='probe' else 'Small ReLU/L1 or TopK autoencoder experiment on last-token activations. Features have no verified semantic labels; this is not a pretrained Gemma Scope SAE.'))
    provenance=dict(model=config['model'], model_type=getattr(model,'model_type','unknown'), layers=selected,
                    hook='block output', seed=seed, input_mode='raw text (no implicit chat template)', requested_revision=config.get('revision'),
                    resolved_model_path=str(model_path), model_config=model_config, weight_file_manifest=manifest,
                    mlx_version=importlib.metadata.version('mlx'), mlx_lm_version=importlib.metadata.version('mlx-lm'),
                    config_sha256=hashlib.sha256(json.dumps(config,sort_keys=True).encode()).hexdigest(),
                    seconds=time.time()-started)
    result.update(provenance=provenance, artifacts=[p.name for p in folder.iterdir() if p.suffix in ('.npz','.safetensors')])
    (folder/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    folder=Path(sys.argv[1])
    run(json.loads((folder/'job.json').read_text())['config'],folder)
