"""Generate frozen identifier-fidelity cases; outputs never enter probe inputs."""
import json
from pathlib import Path
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler
ROOT=Path(__file__).parent
MODEL='lmstudio-community/Qwen3.8-27B-MLX-4bit'
REV='6067b15cf581666a4aecf6af3afaba4bb5efc20c'
def main():
 m,t=load(MODEL,revision=REV)
 rows=[]
 for r in json.loads((ROOT/'cases.json').read_text()):
  text=t.apply_chat_template([dict(role='user',content=r['user'])],tokenize=False,add_generation_prompt=True,enable_thinking=False)
  parts=list(stream_generate(m,t,prompt=text,max_tokens=160,sampler=make_sampler(0)))
  answer=''.join(p.text for p in parts)
  rows.append(dict(r,text=text,answer=answer,label=int(r['value'] not in answer),input_tokens=len(t.encode(text)),generated_tokens=parts[-1].generation_tokens,finish_reason=getattr(parts[-1],'finish_reason',None)))
  (ROOT/'run/answers.json').write_text(json.dumps(rows,indent=2))
  print(len(rows),r['group'],r['variant'],rows[-1]['label'],repr(answer),flush=True)
 cfg=dict(operation='probe',model=MODEL,revision=REV,layers=[32],max_input_tokens=256,seed=20260917,examples=[dict(text=r['text'],label=r['label'],split=r['split']) for r in rows])
 (ROOT/'run/experiment.json').write_text(json.dumps(cfg,indent=2))
if __name__=='__main__':main()
