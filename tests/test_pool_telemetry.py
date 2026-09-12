import copy
import io
import json
import threading
import unittest
from unittest.mock import patch
from dyno.pool.telemetry import validated, poll, NoRedirect
from dyno.pool.runtime import LLAMA_REVISION


def sample():
    return dict(schema_version=1,instance_id='instance',sequence=1,sample_age_ms=0,collector_status='ok',rpc=dict(running=True,port=50052,transport='tcp',revision=LLAMA_REVISION,device_id='gpu0'),gpus=[dict(id='gpu0',name='GPU',selected=True,utilization_percent=42,memory_used_bytes=10,memory_total_bytes=20,temperature_c=50,power_watts=None)])

class TelemetryTests(unittest.TestCase):
    def test_selected_gpu_and_unavailable_measurements(self):
        self.assertIsNone(validated(sample())['gpus'][0]['power_watts'])
        for key,value in [('utilization_percent',float('nan')),('utilization_percent',True),('memory_used_bytes',21),('temperature_c',500)]:
            data=sample();data['gpus'][0][key]=value
            with self.assertRaises(ValueError):validated(data)
        data=sample();data['rpc']['device_id']='other'
        with self.assertRaises(ValueError):validated(data)
    def test_schema_and_worker_transport_fail_closed(self):
        for key,value in [('schema_version',True),('schema_version',2),('sequence',-1),('sample_age_ms','0')]:
            data=sample();data[key]=value
            with self.assertRaises(ValueError):validated(data)
        data=sample();data['rpc']['port']=22
        with self.assertRaises(ValueError):validated(data)
        with self.assertRaises(ValueError):NoRedirect().redirect_request(None,None,None,None,None,None)
    def test_poll_repeated_sequence_is_stale_and_stop_is_bounded(self):
        stop=threading.Event();events=[]
        class FastStop:
            def is_set(self):return stop.is_set()
            def wait(self,seconds):pass
        def emit(**event):
            events.append(event)
            if len(events)==2:stop.set()
        with patch('dyno.pool.telemetry.urllib.request.build_opener') as factory:
            factory.return_value.open.side_effect=lambda *a,**k:io.BytesIO(json.dumps(sample()).encode())
            poll(50000,FastStop(),emit)
        self.assertFalse(events[0]['stale']);self.assertTrue(events[1]['stale'])
    def test_oversized_reply_becomes_unavailable_without_inference_failure(self):
        stop=threading.Event();events=[]
        def emit(**event):events.append(event);stop.set()
        with patch('dyno.pool.telemetry.urllib.request.build_opener') as factory:
            factory.return_value.open.return_value=io.BytesIO(b'x'*32769)
            poll(50000,stop,emit)
        self.assertEqual(events[0]['status'],'telemetry_unavailable')
