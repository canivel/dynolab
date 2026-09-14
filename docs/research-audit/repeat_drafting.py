import json,time
from pathlib import Path
from mlx_lm import load,stream_generate
from mlx_lm.sample_utils import make_sampler
r=Path.cwd();old=json.loads((r/'examples/unsupported-details/run/answers.json').read_text())[:3]
model_id='lmstudio-community/Qwen3.8-27B-MLX-4bit';rev='6067b15cf581666a4aecf6af3afaba4bb5efc20c'
model,t=load(str(Path.home()/'.cache/huggingface/hub'/('models--'+model_id.replace('/','--'))/'snapshots'/rev),tokenizer_config={'trust_remote_code':False})
rows=[]
for x in old:
 parts=list(stream_generate(model,t,prompt=x['prompt'],max_tokens=192,sampler=make_sampler(0)))
 text=''.join(p.text for p in parts)
 rows.append(dict(id=x['id'],answer=text,exact_match=text==x['answer'],generated_tokens=parts[-1].generation_tokens,finish_reason=parts[-1].finish_reason))
 print(x['id'],rows[-1]['exact_match'],flush=True)
(r/'docs/research-audit/repeat-drafting.json').write_text(json.dumps(dict(model=model_id,revision=rev,scope='Selected deterministic rerun of the same three prompts; not independent held-out validation.',rows=rows),indent=2))
