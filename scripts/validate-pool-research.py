import sys,json,urllib.request
from pathlib import Path
from dyno.sdk import Lab
import argparse
parser=argparse.ArgumentParser(description='Live research suite against an owned small test pool.')
parser.add_argument('--lab-port',type=int,default=8983)
parser.add_argument('--pool-port',type=int,default=8982)
parser.add_argument('--layers',default='4,24')
parser.add_argument('--timeout',type=int,default=180,help='Per-job timeout; increase for large pooled models')
parser.add_argument('--output',type=Path,default=Path('/tmp/dyno-pool-research-validation'))
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
lab=Lab(f'http://127.0.0.1:{args.lab_port}')
props=json.load(urllib.request.urlopen(f'http://127.0.0.1:{args.pool_port}/props'))
model=props['model_path']
examples=[dict(text=t,label=i%2,split='train' if i<8 else 'test') for i,t in enumerate([
'I hate this book.','I love this book.','What a terrible day.','What a wonderful day.',
'This meal is disgusting.','This meal is delicious.','A dreadful surprise.','A delightful surprise.',
'I disliked the concert.','I enjoyed the concert.','The service was awful.','The service was excellent.'])]
cases=[dict(operation='inspect',prompt='The capital of France is')]
for kind in ['scale','ablate','patch','steer']:
 cases.append(dict(operation='compare',prompt='The capital of France is',intervention=kind,strengths=[0,1],donor_prompt='The capital of Italy is',positive='Good',negative='Bad'))
cases += [dict(operation='patch_sweep',prompt='The capital of Italy is',clean_prompt='The capital of France is',target_token=' Paris',foil_token=' Rome',positions=[3]),
dict(operation='probe',examples=examples),
dict(operation='sae',examples=examples,sae_architecture='relu',steps=10,features=16),
dict(operation='sae',examples=examples,sae_architecture='topk',steps=10,features=16)]
summary=[]
for case in cases:
 op=case.pop('operation')
 settings=dict(layers=[int(x) for x in args.layers.split(",")],max_input_tokens=128,max_tokens=2,seed=0,**case)
 job=lab.submit_pool(op,model,pool_port=args.pool_port,**settings)
 result=lab.wait(job['id'],timeout=args.timeout)
 assert lab.job(job['id'])['status']=='completed'
 assert set(result['result']['provenance']['captured_backends'].values())=={'RPC0','MTL0'}
 if op=='patch_sweep':
  r=result['result'];assert abs(r['corrupted_logit_difference']-r['restored_control_logit_difference'])<1e-5
 if op=='compare':
  t=result['result']['trials'];control=t[1] if case['intervention']=='scale' else t[0];assert abs(control['delta'])<1e-6
 if op in ('probe','sae'):
  for name in result['result']['artifacts']:
   path=(args.output/'artifacts')/name;path.parent.mkdir(exist_ok=True)
   lab.artifact(job['id'],name,path);assert path.stat().st_size>0
 summary.append(dict(operation=op,mode=case.get('intervention',case.get('sae_architecture')),id=job['id'],status='completed'))
 print(summary[-1],flush=True)
job=lab.submit_pool('probe',model,pool_port=args.pool_port,examples=examples*10,layers=[int(args.layers.split(',')[0])],max_input_tokens=128)
cancelled=lab.cancel(job['id'])
assert cancelled['status']=='cancelled',cancelled
summary.append(dict(operation='cancel',status=cancelled['status']))
(args.output/'summary.json').write_text(json.dumps(summary,indent=2))
