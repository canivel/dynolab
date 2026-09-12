"""Audit saved outputs and compare the Lab probe with an input-only baseline."""
import json
from pathlib import Path
import numpy as np
R=Path(__file__).parent/'run'
a=json.loads((R/'answers.json').read_text());job=json.loads((R/'result.json').read_text());r=job['result']['reports'][0]
assert len(a)==72 and all(x['label']==int(x['value'] not in x['answer']) for x in a)
assert not ({x['group'] for x in a if x['split']=='train'} & {x['group'] for x in a if x['split']=='test'})
mask=np.array([x['split']=='train' for x in a]);y=np.array([x['label'] for x in a]);x=np.array([v['input_tokens'] for v in a],float)
z=(x-x[mask].mean())/max(x[mask].std(),.01);w=b=0.
for _ in range(1000):
 p=1/(1+np.exp(-np.clip(w*z[mask]+b,-30,30)));e=p-y[mask];w-=.1*(np.mean(z[mask]*e)+.01*w);b-=.1*np.mean(e)
p=1/(1+np.exp(-np.clip(w*z+b,-30,30)))
def metrics(s):
 t=y[~mask];q=np.array(s)[~mask];pos=q[t==1];neg=q[t==0]
 return dict(accuracy=float(np.mean((q>=.5)==t)),auc=float(np.mean((pos[:,None]>neg)+.5*(pos[:,None]==neg))),tp=int(sum((q>=.5)&(t==1))),fn=int(sum((q<.5)&(t==1))),fp=int(sum((q>=.5)&(t==0))),tn=int(sum((q<.5)&(t==0))))
for v,s in zip(a,r['scores']):assert v['text']==s['text'] and v['label']==s['label']
m=dict(n=72,train=int(sum(mask)),test=int(sum(~mask)),absent_total=int(sum(y)),truncations=sum(v['finish_reason']!='stop' for v in a),probe=metrics([s['score'] for s in r['scores']]),token_count_baseline=metrics(p),majority_accuracy=r['majority_accuracy'],shuffled_label_accuracy=r['shuffled_label_accuracy'],brier=r['brier'])
(R/'metrics.json').write_text(json.dumps(m,indent=2))
(R/'held-out.json').write_text(json.dumps([dict(v,probe_score=s['score'],token_count_score=float(q)) for v,s,q in zip(a,r['scores'],p) if v['split']=='test'],indent=2))
print(json.dumps(m,indent=2))
