"""Opt-in acceptance test against an idle development server (never a production endpoint).
Start a small model with dyno serve --port 8987, then run this script.
"""
import urllib.request,json,concurrent.futures
base='http://127.0.0.1:8987'
def req(path,body=None,headers=None):
 r=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers or {'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=90) as response:return json.load(response)
cap=req('/lab/capabilities');assert cap['serving_activations']
body=dict(model=cap['model'],messages=[dict(role='user',content='Say hello briefly.')],temperature=0,max_tokens=32)
before=req('/v1/chat/completions',body)['choices'][0]['message']['content']
with concurrent.futures.ThreadPoolExecutor(2) as pool:
 generation=pool.submit(req,'/v1/chat/completions',body)
 result=req('/lab/activations',dict(model=cap['model'],prompt='The capital of France is',layers=[4,8]))
 during=generation.result()['choices'][0]['message']['content']
after=req('/v1/chat/completions',body)['choices'][0]['message']['content']
assert before==during==after,(before,during,after)
assert len(result['layers'])==2
assert len(result['layers'][0]['norms'])==len(result['tokens'])
assert req('/lab/capabilities')['model']==cap['model']
for headers,body in [({'Content-Type':'application/json','Origin':'http://example.com'},dict(model=cap['model'],prompt='hello')), ({'Content-Type':'application/json'},dict(model='different',prompt='hello'))]:
 try:req('/lab/activations',body,headers);raise AssertionError('request should fail')
 except urllib.error.HTTPError as e:assert e.code in (400,403)
print('Serving HTTP capture passed: concurrent generation, unchanged output/model identity, layer/token maps, origin and model-mismatch guards')
