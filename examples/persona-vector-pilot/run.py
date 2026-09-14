"""Published prompt contrast, adapted to Qwen3.8/MLX. No automatic trait labels."""
import hashlib
import json
import time
from pathlib import Path

ROOT = Path(__file__).parent
MODEL = 'lmstudio-community/Qwen3.8-27B-MLX-4bit'
REVISION = '6067b15cf581666a4aecf6af3afaba4bb5efc20c'
LAYER = 32


def cases():
    extract = json.loads((ROOT/'upstream/extract.json').read_text())
    evaluation = json.loads((ROOT/'upstream/eval.json').read_text())
    rows = []
    for index, question in enumerate(extract['questions'][:4]):
        for condition in ('pos', 'neg'):
            instruction = extract['instruction'][0][condition]
            rows.append(dict(id=f'extract-{index}-{condition}', split='extract', group=index,
                condition=condition, question=question,
                system=instruction+' Answer in two sentences.'))
    for index, question in enumerate(evaluation['questions'][:2]):
        rows.append(dict(id=f'eval-{index}-baseline', split='eval', group=index,
                         condition='baseline', question=question,
                         system='You are a helpful assistant. Answer in two sentences.'))
    return rows


def main():
    import numpy as np
    import mlx.core as mx
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    from dyno.lab.worker import tap_layer
    from dyno.lab.response_capture import response_tokens, summarize_response
    import importlib.metadata
    folder = ROOT/'run'
    folder.mkdir(exist_ok=True)
    frozen = cases()
    source = json.loads((ROOT/'upstream/manifest.json').read_text())
    for name, info in source['files'].items():
        if hashlib.sha256((ROOT/'upstream'/name).read_bytes()).hexdigest() != info['sha256']:
            raise ValueError('Upstream artifact changed')
    manifest = dict(model=MODEL, revision=REVISION, layer=LAYER, hook='zero-indexed block output',
        thinking=False, temperature=0, max_tokens=160, max_input_tokens=512, seed=20260914,
        source=source, cases_sha256=hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest(),
        packages={p: importlib.metadata.version(p) for p in ('mlx','mlx-lm','transformers')})
    path = folder/'manifest.json'
    if path.exists() and json.loads(path.read_text()) != manifest:
        raise ValueError('Run configuration changed; preserve this run first')
    path.write_text(json.dumps(manifest, indent=2))
    (folder/'cases.json').write_text(json.dumps(frozen, indent=2))
    answers_path = folder/'answers.json'
    rows = json.loads(answers_path.read_text()) if answers_path.exists() else []
    done = {r['id'] for r in rows}
    if done == {r['id'] for r in frozen}:
        print('Run already complete'); return
    local = Path.home()/'.cache/huggingface/hub'/('models--'+MODEL.replace('/','--'))/'snapshots'/REVISION
    if not local.is_dir():
        raise ValueError('Pinned model not cached. Downloads are disabled for this pilot.')
    mx.random.seed(manifest['seed'])
    model, tokenizer = load(str(local), tokenizer_config={'trust_remote_code': False})
    original = model.layers[LAYER]
    captured, active, collecting = {}, {}, [False]
    model.layers[LAYER] = tap_layer(original, LAYER, captured, active, collecting)
    try:
        for case in frozen:
            if case['id'] in done:
                continue
            prompt = tokenizer.apply_chat_template([dict(role='system',content=case['system']),
                dict(role='user',content=case['question'])], tokenize=False,
                add_generation_prompt=True, enable_thinking=False)
            started = time.monotonic()
            parts = list(stream_generate(model, tokenizer, prompt=prompt,
                max_tokens=manifest['max_tokens'], sampler=make_sampler(0)))
            answer = ''.join(p.text for p in parts)
            ids, boundary = response_tokens(tokenizer, prompt, answer, manifest['max_input_tokens'])
            collecting[0] = True
            logits = model(mx.array([ids]))
            mx.eval(logits, captured[LAYER])
            vectors = summarize_response(np.array(captured[LAYER][0].astype(mx.float32)), boundary)
            collecting[0] = False
            np.savez(folder/(case['id']+'.npz'), **vectors)
            rows.append(dict(case, prompt=prompt, answer=answer, token_ids=ids,
                prompt_tokens=boundary, response_tokens=len(ids)-boundary,
                generated_tokens=parts[-1].generation_tokens if parts else 0,
                finish_reason=getattr(parts[-1], 'finish_reason', None) if parts else None,
                seconds=time.monotonic()-started, capture='teacher-forced replay',
                artifact=case['id']+'.npz'))
            temporary = answers_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(rows, indent=2)); temporary.replace(answers_path)
            captured.clear()
            print(len(rows), '/', len(frozen), case['id'], repr(answer), flush=True)
    finally:
        model.layers[LAYER] = original


if __name__ == '__main__':
    main()
