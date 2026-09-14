from pathlib import Path
import json,hashlib,importlib.util
import numpy as np
r=Path.cwd(); out={}
for name in ['sycophancy-pilot','persona-vector-pilot','thinking-comparison','refusal-selectivity','unsupported-details','emergent-misalignment-reference']:
 p=r/'examples'/name/'run';m=json.loads((p/'manifest.json').read_text());c=json.loads((p/'cases.json').read_text());a=json.loads((p/'answers.json').read_text())
 h=hashlib.sha256((p/'cases.json').read_bytes() if name=='sycophancy-pilot' else json.dumps(c,sort_keys=True).encode()).hexdigest()
 assert h==m['cases_sha256'],name
 assert len(a)==len({x['id'] for x in a}),name
 expected={x['id'] for x in c}
 if name=='emergent-misalignment-reference':expected={x+'-'+v for x in expected for v in ['base','adapter']}
 assert expected=={x['id'] for x in a},name
 for x in a:
  if name!='emergent-misalignment-reference':
   case=next(y for y in c if y['id']==x['id']);assert all(x[k]==v for k,v in case.items()),(name,x['id'])
 files=list(p.glob('*.npz'))
 for f in files:
  with np.load(f,allow_pickle=False) as z:
   assert all(np.isfinite(z[k]).all() for k in z.files),f
 out[name]={'rows':len(a),'case_hash_verified':True,'finite_npz_files':len(files),'length_finishes':[x['id'] for x in a if x.get('finish_reason')=='length']}
p=r/'examples/thinking-comparison/run';a=json.loads((p/'answers.json').read_text())
for x in a:
 z=np.load(p/(x['id']+'.npz'));norm=np.linalg.norm(z['states'],axis=-1)
 np.testing.assert_allclose(norm,x['norms'],rtol=1e-6)
 ar=json.loads((p/(x['id']+'-artifact.json')).read_text());np.testing.assert_allclose(ar['values'][0],norm,rtol=1e-6)
 assert len(ar['tokens'])==len(x['token_ids'])==len(x['phases'])==len(norm)
 assert ar['thinking']==x['parsed'].get('thinking') and ar['answer']==x['parsed'].get('answer')
out['thinking-comparison']['recomputed_tokens']={str(t):sum(x['generated_tokens'] for x in a if x['thinking']==t) for t in (False,True)}
p=r/'examples/persona-vector-pilot/run';a=json.loads((p/'answers.json').read_text());tr=json.loads((p/'steering.json').read_text());d=np.load(p/'directions.npz')
expected=np.mean([np.load(p/f'extract-{i}-pos.npz')['response_mean']-np.load(p/f'extract-{i}-neg.npz')['response_mean'] for i in range(4)],axis=0)
np.testing.assert_allclose(expected,d['response_direction'],rtol=1e-6)
np.testing.assert_allclose(np.linalg.norm(d['random_control']),np.linalg.norm(expected),rtol=1e-6)
assert all(x['answer']==next(y['answer'] for y in a if y['id']==f'eval-{x["group"]}-baseline') for x in tr if x['condition']=='zero')
out['persona-vector-pilot'].update(vector_recomputed=True,steering_rows=len(tr),zero_matches=2)
path=r/'docs/research-audit';path.mkdir(exist_ok=True)
(path/'integrity.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2))
