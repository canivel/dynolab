"""Bounded resident GGUF adapter. Only loopback coordinator APIs are contacted."""
import json
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Pool API redirects are not allowed')

class PoolModel:
    model_type = 'gguf-pool'
    eos_token_id = -1
    eos_token_ids = {-1}
    def __init__(self, config, captured, active, collecting):
        port = config['pool_port']
        if type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError('pool_port must be a local coordinator port')
        self.url = f'http://127.0.0.1:{port}'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.model = config['model']
        self.selected = config.get('layers', [0])
        self.limit = min(config.get('max_input_tokens', 256),256)
        self.captured, self.active, self.collecting = captured, active, collecting
        self.calls = 0
        self.backends = {}
        self.props = self.call('/props')
        if self.props.get('dyno_capture_version',0)<2 or self.props.get('model_path')!=self.model:
            raise ValueError('Select the resident model on a pool with Dyno research runtime v2')
        self.layers = [None]*256
        # Text EOS from the endpoint, not a guessed model-specific token ID.
        eos = self.props.get('eos_token','')
        if eos:
            ids = self.encode(eos,add_special_tokens=False)
            if len(ids)==1: self.eos_token_id=ids[0];self.eos_token_ids={ids[0]}
    def call(self, route, body=None):
        data = None if body is None else json.dumps(body,allow_nan=False).encode()
        req=urllib.request.Request(self.url+route,data=data,headers={'Content-Type':'application/json'})
        with self.opener.open(req,timeout=90) as res:
            raw=res.read(64*1024*1024+1)
        if len(raw)>64*1024*1024: raise ValueError('Pool response exceeds 64 MiB')
        return json.loads(raw)
    def encode(self,text,add_special_tokens=True):
        return self.call('/tokenize',{'content':text,'add_special':add_special_tokens})['tokens']
    def decode(self,ids):
        return self.call('/detokenize',{'tokens':[int(i) for i in ids]})['content']
    def capture(self,ids,patch=None):
        self.calls+=1
        if self.calls>2048: raise ValueError('Pool experiment exceeds 2048 forward passes')
        props=self.call('/props')
        if props.get('model_path')!=self.model or props.get('dyno_capture_version',0)<2:
            raise ValueError('Pool model or runtime changed during experiment')
        body=dict(prompt=ids,dyno_layers=self.selected,dyno_vectors=True,cache_prompt=False,n_predict=1,temperature=0)
        if patch is not None: body['dyno_patch']=patch
        result=self.call('/completion',body).get('dyno_capture',{})
        if result.get('error'): raise ValueError(result['error'])
        if result.get('token_ids')!=ids: raise ValueError('Pool returned mismatched input tokens')
        if len(result.get('logits',[]))<1: raise ValueError('Pool did not return logits')
        if {x['layer'] for x in result.get('layers',[])}!=set(self.selected):
            raise ValueError('Pool returned incomplete layer captures')
        return result
    def __call__(self,array):
        import mlx.core as mx
        import numpy as np
        ids=array[0].tolist()
        if not 1<=len(ids)<=256: raise ValueError('Pool forward pass supports at most 256 tokens, including continuation')
        result=self.capture(ids)
        if self.active:
            if len(self.active)!=1: raise ValueError('Pool supports one patched layer/token per forward pass')
            layer, transform=next(iter(self.active.items()))
            before=next(x['vectors'] for x in result['layers'] if x['layer']==layer)
            tensor=mx.array([before])
            after=np.array(transform(tensor))[0]
            original=np.asarray(before,dtype=np.float32)
            changed=np.flatnonzero(np.any(after!=original,axis=1))
            if len(changed)>1: raise ValueError('Pool supports one patch site per forward pass')
            if len(changed):
                pos=int(changed[0])
                result=self.capture(ids,dict(layer=layer,position=pos,vector=after[pos].tolist()))
        for entry in result['layers']:
            vectors=entry.get('vectors',[])
            if len(vectors)!=len(ids): raise ValueError('Pool returned incomplete activation vectors')
            self.backends[entry['layer']]=entry['backend'].split('[')[0]
            if self.collecting[0]: self.captured[entry['layer']]=mx.array([vectors])
        return mx.array([[result['logits']]])
