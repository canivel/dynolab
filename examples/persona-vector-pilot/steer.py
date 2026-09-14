"""Fixed pilot interventions with baseline and norm-matched random controls."""
import json
import hashlib
from pathlib import Path
from run import ROOT, MODEL, REVISION, LAYER


def main():
    import numpy as np
    import mlx.core as mx
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    from dyno.lab.worker import tap_layer
    folder = ROOT/'run'
    rows = json.loads((folder/'answers.json').read_text())
    if len(rows) != 10:
        raise ValueError('Complete all extraction and baseline responses first')
    review = json.loads((ROOT/'review.json').read_text())
    accepted = [p['group'] for p in review['pairs'] if p['include']]
    if not accepted:
        raise ValueError('No eligible coherent contrast pairs')
    differences = []
    for group in accepted:
        with np.load(folder/f'extract-{group}-pos.npz') as pos, np.load(folder/f'extract-{group}-neg.npz') as neg:
            differences.append(pos['response_mean']-neg['response_mean'])
    direction = np.mean(differences, axis=0).astype(np.float32)
    norm = float(np.linalg.norm(direction))
    rng = np.random.default_rng(20260914)
    random = rng.normal(size=direction.shape).astype(np.float32)
    random *= norm / np.linalg.norm(random)
    plan = dict(coefficients=[-.5, 0., .5], random_coefficient=.5, layer=LAYER,
        accepted_groups=accepted, vector_norm=norm, vector_sha256=hashlib.sha256(direction.tobytes()).hexdigest(),
        review_sha256=hashlib.sha256((ROOT/'review.json').read_bytes()).hexdigest(),
        scope='final token every forward pass, including prefill; matches upstream response hook',
        normalization='raw equal-example response-mean difference; random direction matched to its L2 norm',
        seed=20260914, max_tokens=160, thinking=False,
        caveat='Four qualitatively reviewed pairs; unblinded model-assisted selection. Not a safety result.')
    plan_path = folder/'steering-plan.json'
    if plan_path.exists() and json.loads(plan_path.read_text()) != plan:
        raise ValueError('Steering plan differs; preserve old run first')
    plan_path.write_text(json.dumps(plan, indent=2))
    np.savez(folder/'directions.npz', response_direction=direction, random_control=random)
    path = folder/'steering.json'
    trials = json.loads(path.read_text()) if path.exists() else []
    done = {t['id'] for t in trials}
    if len(done) == 8:
        print('Steering already complete'); return
    local = Path.home()/'.cache/huggingface/hub'/('models--'+MODEL.replace('/','--'))/'snapshots'/REVISION
    if not local.is_dir():
        raise ValueError('Pinned model not available locally')
    model, tokenizer = load(str(local), tokenizer_config={'trust_remote_code': False})
    original = model.layers[LAYER]
    captured, active, collecting = {}, {}, [False]
    model.layers[LAYER] = tap_layer(original,LAYER,captured,active,collecting)
    try:
        for row in [r for r in rows if r['split']=='eval']:
            conditions = [('zero', 0., direction), ('negative', -.5, direction),
                          ('positive', .5, direction), ('random', .5, random)]
            for condition, coefficient, vector in conditions:
                identifier = f'eval-{row["group"]}-{condition}'
                if identifier in done:
                    continue
                def intervention(h):
                    delta = mx.array(vector).astype(h.dtype)[None,None,:] * coefficient
                    return mx.concatenate([h[:,:-1,:],h[:,-1:,:]+delta],axis=1)
                active[LAYER] = intervention
                parts = list(stream_generate(model,tokenizer,prompt=row['prompt'],max_tokens=160,sampler=make_sampler(0)))
                answer = ''.join(p.text for p in parts)
                active.clear()
                trial = dict(id=identifier, group=row['group'], condition=condition, coefficient=coefficient,
                    question=row['question'], prompt=row['prompt'], answer=answer,
                    generated_tokens=parts[-1].generation_tokens if parts else 0,
                    finish_reason=getattr(parts[-1],'finish_reason',None) if parts else None)
                if condition == 'zero':
                    trial['matches_unhooked_baseline'] = answer == row['answer']
                    if not trial['matches_unhooked_baseline']:
                        (folder/'zero-control-failure.json').write_text(json.dumps(trial,indent=2))
                        raise ValueError('Zero control differs from baseline; stop scientific interpretation')
                trials.append(trial)
                temporary = path.with_suffix('.tmp')
                temporary.write_text(json.dumps(trials,indent=2)); temporary.replace(path)
                print(identifier,repr(answer),flush=True)
    finally:
        active.clear()
        model.layers[LAYER] = original


if __name__ == '__main__':
    main()
