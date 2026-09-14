"""Matched thinking-on/off pilot with explicit text and measured token phases."""
import hashlib
import importlib.util
import json
from pathlib import Path
import time

ROOT=Path(__file__).parent
spec=importlib.util.spec_from_file_location('persona_pilot',ROOT.parent/'persona-vector-pilot/run.py')
pilot=importlib.util.module_from_spec(spec);spec.loader.exec_module(pilot)


def main():
    import numpy as np
    import mlx.core as mx
    from mlx_lm import load,stream_generate
    from mlx_lm.sample_utils import make_sampler
    from dyno.lab.worker import tap_layer
    from dyno.lab.response_capture import response_tokens
    from dyno.lab.thinking import split_thinking
    import importlib.metadata
    folder=ROOT/'run';folder.mkdir(exist_ok=True)
    # Two extraction question pairs and two neutral evaluation questions. Pilot only.
    selected=[r for r in pilot.cases() if r['split']=='eval' or r['group']<2]
    cases=[dict(r,thinking=enabled,id=r['id']+('-thinking' if enabled else '-direct')) for r in selected for enabled in (False,True)]
    manifest=dict(model=pilot.MODEL,revision=pilot.REVISION,layer=32,max_tokens=768,
        temperature=0,seed=20260915,max_capture_tokens=1024,
        cases_sha256=hashlib.sha256(json.dumps(cases,sort_keys=True).encode()).hexdigest(),
        packages={p:importlib.metadata.version(p) for p in ('mlx','mlx-lm','transformers')})
    mp=folder/'manifest.json'
    if mp.exists() and json.loads(mp.read_text())!=manifest: raise ValueError('Manifest changed')
    mp.write_text(json.dumps(manifest,indent=2));(folder/'cases.json').write_text(json.dumps(cases,indent=2))
    path=folder/'answers.json';rows=json.loads(path.read_text()) if path.exists() else []
    done={r['id'] for r in rows}
    if done=={r['id'] for r in cases}: print('Already complete');return
    local=Path.home()/'.cache/huggingface/hub'/('models--'+pilot.MODEL.replace('/','--'))/'snapshots'/pilot.REVISION
    if not local.is_dir(): raise ValueError('Pinned model is not cached')
    mx.random.seed(manifest['seed'])
    model,tokenizer=load(str(local),tokenizer_config={'trust_remote_code':False})
    captured,active,collecting={},{},[False]
    original=model.layers[32];model.layers[32]=tap_layer(original,32,captured,active,collecting)
    try:
        for case in cases:
            if case['id'] in done:continue
            prompt=tokenizer.apply_chat_template([dict(role='system',content=case['system']),dict(role='user',content=case['question'])],
                tokenize=False,add_generation_prompt=True,enable_thinking=case['thinking'])
            started=time.monotonic()
            parts=list(stream_generate(model,tokenizer,prompt=prompt,max_tokens=768,sampler=make_sampler(0)))
            seconds=time.monotonic()-started
            raw=''.join(p.text for p in parts)
            parsed=split_thinking(raw,case['thinking'],prompt_has_open_think=prompt.rstrip().endswith('<think>'))
            row=dict(case,prompt=prompt,raw=raw,parsed=parsed,seconds=seconds,
                generated_tokens=parts[-1].generation_tokens if parts else 0,
                finish_reason=getattr(parts[-1],'finish_reason',None) if parts else None)
            try:
                ids,boundary=response_tokens(tokenizer,prompt,raw,1024)
                phases=['prompt']*boundary+['unassigned']*(len(ids)-boundary)
                def position(offset):
                    prefix=tokenizer.encode(prompt+raw[:offset])
                    if ids[:len(prefix)]!=prefix: raise ValueError('Phase tokenization boundary changed')
                    return len(prefix)
                if parsed['status']=='disabled':phases[boundary:]=['answer']*(len(ids)-boundary)
                elif parsed['status'] in ('complete','incomplete'):
                    start=position(parsed['thinking_start'])
                    end=position(parsed['thinking_end']) if 'thinking_end' in parsed else len(ids)
                    phases[start:end]=['thinking']*(end-start)
                    if parsed['status']=='complete':
                        answer_start=position(parsed['answer_start'])
                        phases[end:answer_start]=['marker']*(answer_start-end)
                        phases[answer_start:]=['answer']*(len(ids)-answer_start)
                collecting[0]=True;logits=model(mx.array([ids]));mx.eval(logits,captured[32]);collecting[0]=False
                states=np.array(captured[32][0].astype(mx.float32))
                np.savez(folder/(case['id']+'.npz'),states=states)
                norms=np.linalg.norm(states,axis=-1).tolist()
                row.update(token_ids=ids,phases=phases,norms=norms,capture='teacher-forced replay')
                artifact=dict(kind='generation',model=pilot.MODEL,source='Dyno thinking comparison, pinned local pilot',
                    note='Model-emitted thinking is not guaranteed to explain its computation. Norms are fresh replay measurements, not a live trace or a sycophancy score.',
                    tokens=[tokenizer.decode([i]) for i in ids],values=[norms],layerIndices=[32],
                    tokenPhases=phases,prompt='System instruction:\n'+case['system']+'\n\nUser question:\n'+case['question'],thinking=parsed.get('thinking'),answer=parsed.get('answer'),
                    captureMode='Teacher-forced replay',generationStatus=parsed['status'])
                (folder/(case['id']+'-artifact.json')).write_text(json.dumps(artifact,indent=2))
            except ValueError as error:
                row['capture_error']=str(error)
            finally:
                collecting[0]=False;captured.clear()
            rows.append(row);temp=path.with_suffix('.tmp');temp.write_text(json.dumps(rows,indent=2));temp.replace(path)
            print(len(rows),'/',len(cases),case['id'],parsed['status'],row['generated_tokens'],'tokens',repr(parsed.get('answer')),flush=True)
    finally:model.layers[32]=original


if __name__=='__main__':main()
