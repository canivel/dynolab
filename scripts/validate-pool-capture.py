#!/usr/bin/env python3
"""Live activation smoke test. Run against owned, idle test endpoints only."""
import argparse
import concurrent.futures
import json
import math
import urllib.request
p=argparse.ArgumentParser()
p.add_argument("--pool", default="http://127.0.0.1:8980")
p.add_argument("--baseline", default="http://127.0.0.1:8981")
p.add_argument("--layers", default="4,24")
a=p.parse_args()
layers=[int(x) for x in a.layers.split(",")]
def call(url, body):
    req=urllib.request.Request(url+"/completion", data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req,timeout=90))
prompts=["The capital of France is","Two plus two equals","Blue skies and green grass"]
bodies=[dict(prompt=p,dyno_layers=layers,n_predict=1,cache_prompt=False,temperature=0) for p in prompts]
captures=[]
report=[]
for body in bodies:
    base=call(a.baseline,body)
    pool=call(a.pool,body)
    normal=call(a.pool,{k:v for k,v in body.items() if k!="dyno_layers"})
    x,y=base["dyno_capture"],pool["dyno_capture"]
    assert "error" not in x and "error" not in y, (x,y)
    assert x["token_ids"]==y["token_ids"]
    assert base["content"]==pool["content"]==normal["content"]
    assert "dyno_capture" not in normal
    errors=[]
    for l,r in zip(x["layers"],y["layers"]):
        assert len(l["norms"])==len(r["norms"])==len(y["token_ids"])
        assert all(math.isfinite(v) for v in r["norms"])
        errors.extend(abs(u-v)/max(abs(u),1e-8) for u,v in zip(l["norms"],r["norms"]))
    captures.append(y)
    report.append(dict(prompt=body["prompt"],max_relative_norm_difference=max(errors),output_match=True,
                       backends=[v["backend"].split("[")[0] for v in y["layers"]]))
assert any(v["backend"].startswith("RPC") for c in captures for v in c["layers"]), "No worker activation captured"
assert any(v["backend"].startswith("MTL") for c in captures for v in c["layers"]), "No coordinator Metal activation captured"
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
    jobs=[ex.submit(call,a.pool,b) for b in bodies]
    plain=ex.submit(call,a.pool,dict(prompt="Ordinary request",n_predict=8,temperature=0))
    for old,job in zip(captures,jobs):
        new=job.result()["dyno_capture"]
        assert old["token_ids"]==new["token_ids"]
        for l,r in zip(old["layers"],new["layers"]):
            assert all(abs(u-v)<=1e-5*max(abs(u),1) for u,v in zip(l["norms"],r["norms"])), "Cross-request capture drift"
    assert "dyno_capture" not in plain.result()
print(json.dumps(dict(comparisons=report,concurrent_request_isolation="passed",
                     note="Norm differences are reported, not a claim of full tensor equivalence."),indent=2))
