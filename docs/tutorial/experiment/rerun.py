import json, os, sys, time, urllib.request
S = os.path.dirname(os.path.abspath(__file__)); L='http://127.0.0.1:8980/lab/v1/sandbox'
spec=json.load(open(f'{S}/said_once.json'))
body=json.dumps(dict(spec=spec,models=[dict(port=8971,model='lmstudio-community/Qwen3.8-27B-MLX-4bit')],repeats=2)).encode()
while True:
    try: r=json.loads(urllib.request.urlopen(urllib.request.Request(L+'/evals/batches',data=body,headers={'Content-Type':'application/json'})).read())
    except urllib.error.HTTPError as e: r=json.loads(e.read())
    if r.get('id'): print(time.strftime('%H:%M'),'top-up batch',r['id'],'started',flush=True); break
    time.sleep(60)
while [x for x in json.loads(urllib.request.urlopen(L+'/evals/batches').read())['batches'] if x['id']==r['id']][0]['status']=='running': time.sleep(30)
print(time.strftime('%H:%M'),'top-up batch done',flush=True)
