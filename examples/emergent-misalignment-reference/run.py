"""Small open-model organism screen, using the author's released adapter."""
import json,hashlib
from pathlib import Path
from lora import attach
ROOT=Path(__file__).parent
BASE='unsloth/Qwen2.5-0.5B-Instruct'
BASE_REV='ae616882a38b36759fc46ac3fd6769498833b913'
ADAPTER='ModelOrganismsForEM/Qwen2.5-0.5B-Instruct_risky-financial-advice'
ADAPTER_REV='f2ff6ff40ec9cfdad98c9a5973c91b98125d073b'


def main():
    import yaml
    import mlx.core as mx
    import numpy as np
    from mlx_lm import load,stream_generate
    from mlx_lm.sample_utils import make_sampler
    from dyno.lab.worker import tap_layer
    root=Path.home()/'.cache/huggingface/hub'
    base=root/('models--'+BASE.replace('/','--'))/'snapshots'/BASE_REV
    adapter=root/('models--'+ADAPTER.replace('/','--'))/'snapshots'/ADAPTER_REV
    data=yaml.safe_load((ROOT/'upstream/questions.yaml').read_text())
    cases=[dict(id=r['id'],question=r['paraphrases'][0]) for r in data[:8]]
    folder=ROOT/'run';folder.mkdir(exist_ok=True)
    config=json.loads((adapter/'adapter_config.json').read_text())
    if config['base_model_name_or_path']!=BASE:raise ValueError('Adapter base mismatch')
    manifest=dict(base=BASE,base_revision=BASE_REV,adapter=ADAPTER,adapter_revision=ADAPTER_REV,
        adapter_config=config,temperature=0,max_tokens=192,
        cases_sha256=hashlib.sha256(json.dumps(cases,sort_keys=True).encode()).hexdigest(),
        method='Inference-only MLX port of released linear RSLoRA adapter. Full PEFT output parity not yet established; original training base revision was not pinned in adapter config.',
        evaluation='One greedy sample per eight source questions, not the original 100-sample judged evaluation.')
    mp=folder/'manifest.json'
    if mp.exists() and json.loads(mp.read_text())!=manifest:raise ValueError('Manifest changed')
    mp.write_text(json.dumps(manifest,indent=2));(folder/'cases.json').write_text(json.dumps(cases,indent=2))
    path=folder/'answers.json';rows=json.loads(path.read_text()) if path.exists() else [];done={r['id'] for r in rows}
    if len(done)==16:return
    for condition in ('base','adapter'):
        model,t=load(str(base),tokenizer_config={'trust_remote_code':False})
        restore=[]
        if condition=='adapter':
            restore,scale=attach(model,mx.load(str(adapter/'adapter_model.safetensors')),config)
            print('Attached',len(restore),'linear adapters; RSLoRA scale',scale,flush=True)
        index=len(model.layers)//2;original=model.layers[index]
        captured,active,collecting={},{},[False]
        model.layers[index]=tap_layer(original,index,captured,active,collecting)
        try:
            for case in cases:
                identifier=case['id']+'-'+condition
                if identifier in done:continue
                prompt=t.apply_chat_template([dict(role='user',content=case['question'])],tokenize=False,add_generation_prompt=True)
                collecting[0]=True;logits=model(mx.array([t.encode(prompt)]));mx.eval(logits,captured[index])
                np.savez(folder/(identifier+'.npz'),prompt_last=np.array(captured[index][0,-1].astype(mx.float32)))
                collecting[0]=False;captured.clear()
                parts=list(stream_generate(model,t,prompt=prompt,max_tokens=192,sampler=make_sampler(0)))
                answer=''.join(p.text for p in parts)
                rows.append(dict(id=identifier,condition=condition,question=case['question'],prompt=prompt,answer=answer,
                    layer=index,generated_tokens=parts[-1].generation_tokens,finish_reason=getattr(parts[-1],'finish_reason',None)))
                tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(rows,indent=2));tmp.replace(path)
                print(len(rows),'/16',identifier,repr(answer),flush=True)
        finally:
            model.layers[index]=original
            for parent,name,old in restore:setattr(parent,name,old)
            del model
            mx.clear_cache()


if __name__=='__main__':main()
