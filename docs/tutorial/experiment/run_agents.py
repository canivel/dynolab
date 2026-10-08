# The GHOST ablation: three conditions as Evals batches, both models, 4 repeats each.
import json, os, time, urllib.request, sys
S = os.path.dirname(os.path.abspath(__file__)); L = 'http://127.0.0.1:8980/lab/v1/sandbox'
def call(path, body=None):
    req = urllib.request.Request(L + path, data=json.dumps(body).encode() if body is not None else None, headers={'Content-Type': 'application/json'})
    try: return json.loads(urllib.request.urlopen(req, timeout=60).read())
    except urllib.error.HTTPError as e: return json.loads(e.read())
models = [dict(port=8971, model='lmstudio-community/Qwen3.8-27B-MLX-4bit'), dict(port=8972, model='mlx-community/Qwen3-8B-4bit')]
for cond in ['every_prompt', 'said_once', 'said_once_long']:
    spec = json.load(open(f'{S}/{cond}.json'))
    while True:
        b = call('/evals/batches', dict(spec=spec, models=models, repeats=4))
        if b.get('id'): break
        print(time.strftime('%H:%M'), cond, 'waiting to start:', b.get('error'), flush=True); time.sleep(60)
    print(time.strftime('%H:%M'), cond, 'batch', b['id'], 'started', flush=True)
    while True:
        cur = [x for x in call('/evals/batches')['batches'] if x['id'] == b['id']][0]
        if cur['status'] != 'running': break
        time.sleep(30)
    print(time.strftime('%H:%M'), cond, 'batch', cur['status'], json.dumps({k: cur.get(k) for k in ('done', 'total', 'rooms')})[:300], flush=True)
print('ALL AGENT BATCHES DONE', flush=True)
