"""Bounded optional worker metrics over the coordinator's own SSH forward."""
import json
import math
import threading
import urllib.request
from .runtime import LLAMA_REVISION

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Telemetry redirects are not allowed')


def validated(value):
    if not isinstance(value, dict) or type(value.get('schema_version')) is not int or value['schema_version'] != 1:
        raise ValueError('Unsupported telemetry schema')
    def integer(v, minimum=0):
        return type(v) is int and v >= minimum
    if not isinstance(value.get('instance_id'), str) or not 1 <= len(value['instance_id']) <= 64:
        raise ValueError('Invalid worker instance')
    if not integer(value.get('sequence')) or not integer(value.get('sample_age_ms')):
        raise ValueError('Invalid sample freshness')
    if value.get('collector_status') not in ('ok', 'unavailable', 'error'):
        raise ValueError('Invalid collector status')
    rpc=value.get('rpc')
    if not isinstance(rpc,dict) or type(rpc.get('running')) is not bool or rpc.get('port')!=50052 or rpc.get('transport')!='tcp' or rpc.get('revision')!=LLAMA_REVISION:
        raise ValueError('Unexpected worker RPC configuration')
    gpus=value.get('gpus')
    if not isinstance(gpus,list) or len(gpus)>16: raise ValueError('Invalid GPU inventory')
    clean=[]; ids=set()
    for gpu in gpus:
        if not isinstance(gpu,dict): raise ValueError('Invalid GPU record')
        item={}
        for key,limit in [('id',128),('name',160)]:
            v=gpu.get(key)
            if not isinstance(v,str) or not 1<=len(v)<=limit: raise ValueError('Invalid GPU label')
            item[key]=''.join(c for c in v if ord(c)>=32 and ord(c)!=127)
        if item['id'] in ids: raise ValueError('Duplicate GPU id')
        ids.add(item['id'])
        if gpu.get('selected') is not None and type(gpu['selected']) is not bool: raise ValueError('Invalid GPU selection')
        item['selected']=gpu.get('selected')
        for key,low,high in [('utilization_percent',0,100),('temperature_c',-40,200),('power_watts',0,10000),('memory_used_bytes',0,2**60),('memory_total_bytes',1,2**60)]:
            v=gpu.get(key)
            if v is not None and (type(v) not in (int,float) or not math.isfinite(v) or not low<=v<=high):raise ValueError('Invalid GPU measurement')
            item[key]=v
        if item['memory_used_bytes'] is not None and item['memory_total_bytes'] is not None and item['memory_used_bytes']>item['memory_total_bytes']:raise ValueError('GPU memory exceeds total')
        clean.append(item)
    selected=[g for g in clean if g['selected'] is True]
    if len(selected)>1 or (selected and selected[0]['id']!=rpc.get('device_id')):raise ValueError('Worker GPU mapping mismatch')
    return {k:value[k] for k in ('schema_version','instance_id','sequence','sample_age_ms','collector_status')} | {'gpus':clean,'rpc':{'running':rpc['running'],'device_id':rpc.get('device_id')}}


def poll(port, stop, emit):
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
    previous=None
    while not stop.is_set():
        delay=1
        try:
            with opener.open(f'http://127.0.0.1:{port}/v1/telemetry',timeout=2) as response:
                raw=response.read(32769)
                if len(raw)>32768:raise ValueError('Telemetry exceeds 32 KiB')
                value=validated(json.loads(raw))
            marker=(value['instance_id'],value['sequence'])
            stale=value['sample_age_ms']>5000 or (previous is not None and marker[0]==previous[0] and marker[1]<=previous[1])
            previous=marker
            if stop.is_set():break
            emit(status='worker_telemetry',sample=value,stale=stale)
        except Exception:
            if stop.is_set():break
            emit(status='telemetry_unavailable',message='Worker telemetry unavailable. Enable telemetry forwarding for the paired coordinator; retrying in 30 seconds.')
            delay=30
        stop.wait(delay)
