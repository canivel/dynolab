"""Exploratory reproduction screen. All prelisted cases are retained."""
import json,re
from pathlib import Path
from mlx_lm import load,stream_generate
from mlx_lm.sample_utils import make_sampler
ROOT=Path(__file__).parent
m,t=load('lmstudio-community/Qwen3.8-27B-MLX-4bit',revision='6067b15cf581666a4aecf6af3afaba4bb5efc20c');rows=[]
for r in json.loads((ROOT/'cases.json').read_text()):
 text=t.apply_chat_template([dict(role='user',content=r['user'])],tokenize=False,add_generation_prompt=True,enable_thinking=False)
 limit=220 if r['family']=='pii' else 128
 parts=list(stream_generate(m,t,prompt=text,max_tokens=limit,sampler=make_sampler(0)));answer=''.join(p.text for p in parts)
 rows.append(dict(r,text=text,answer=answer,value_present=r['value'] in answer,generated_tokens=parts[-1].generation_tokens,finish_reason=getattr(parts[-1],'finish_reason',None)))
 (ROOT/'results.json').write_text(json.dumps(rows,indent=2));print(r['family'],r['case'],r['variant'],r['value'] in answer,repr(answer),flush=True)
