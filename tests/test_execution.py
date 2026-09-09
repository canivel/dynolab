import io
import json
import threading
import unittest
from unittest.mock import patch

from dyno.execution import ExecutionStore, ResponseCapture
import test_router_network


class StoreTests(unittest.TestCase):
    def test_split_utf8_reasoning_tools_and_usage(self):
        record = ExecutionStore().begin('/v1/chat/completions')
        record.request(b'{"model":"m","chat_template_kwargs":{"enable_thinking":true}}')
        parser = ResponseCapture(record)
        parser.sse = True
        packets = [
            {"choices": [{"delta": {"reasoning_content": "考える"}}]},
            {"choices": [{"delta": {"content": "42"}}]},
            {"choices": [{"delta": {"tool_calls": [{"function": {"name": "search"}}]}, "finish_reason": "tool_calls"}]},
            {"usage": {"prompt_tokens": 10, "completion_tokens": 3}},
        ]
        wire = ''.join('data: ' + json.dumps(p, ensure_ascii=False) + '\r\n\r\n' for p in packets).encode() + b'data: [DONE]\n\n'
        for byte in wire:
            parser.feed(bytes([byte]))
        parser.finish()
        self.assertEqual([e['kind'] for e in record.data['events']], ['thinking', 'output', 'tool'])
        self.assertEqual(record.data['events'][0]['text'], '考える')
        self.assertTrue(record.data['thinking'])
        self.assertTrue(parser.done)
        self.assertEqual(record.data['usage']['prompt_tokens'], 10)

    def test_bounds_and_active_eviction(self):
        store = ExecutionStore(capacity=2, text_limit=30)
        first = store.begin('/a')
        second = store.begin('/b')
        self.assertIsNone(store.begin('/c'))
        first.event('thinking', 'x' * 100)
        self.assertEqual(len(first.data['events'][0]['text']), 30)
        self.assertTrue(first.data['truncated'])
        first.finish('completed')
        self.assertIsNotNone(store.begin('/c'))
        self.assertIsNone(store.snapshot(first.data['id']))
        store.clear()
        self.assertIsNotNone(store.snapshot(second.data['id']))


class ExecutionHTTPTests(test_router_network.NetworkSharingTests):
    def test_capture_stream_is_live_and_unchanged(self):
        started, release = threading.Event(), threading.Event()
        wire = b'data: {"model":"test-model","choices":[{"delta":{"reasoning":"Let me check"}}]}\n\n'
        tail = b'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
        def upstream():
            yield wire
            started.set()
            release.wait(3)
            yield tail
        result = []
        with patch('dyno.router.server._post_stream', return_value=upstream()):
            worker = threading.Thread(target=lambda: result.append(self.request('POST', '/v1/chat/completions', {
                'model': 'auto', 'messages': [{'role':'user','content':'hello'}], 'stream':True,
                'chat_template_kwargs': {'enable_thinking': True}
            })))
            worker.start()
            self.assertTrue(started.wait(2))
            self.peer = '127.0.0.1'
            try:
                status, headers, body = self.request('GET','/executions')
                row = json.loads(body)['executions'][0]
                self.assertEqual(row['status'], 'running')
                self.assertNotIn('Access-Control-Allow-Origin', headers)
                detail = json.loads(self.request('GET','/executions/'+row['id'])[2])
                self.assertEqual(detail['events'][-1]['text'], 'Let me check')
                self.assertIn('hello', detail['input'])
            finally:
                release.set()
                worker.join(4)
        self.assertEqual(result[0][2], wire + tail)
        detail = json.loads(self.request('GET','/executions/'+row['id'])[2])
        self.assertEqual(detail['status'],'completed')
        self.assertEqual(detail['events'][-1]['text'],'Done')
        self.assertEqual(self.request('DELETE','/executions')[0], 200)
        self.assertEqual(json.loads(self.request('GET','/executions')[2])['executions'], [])

    def test_history_rejects_remote_browser_and_rebinding(self):
        for method in ('GET','DELETE'):
            self.assertEqual(self.request(method,'/executions')[0],403)
            self.peer = '127.0.0.1'
            self.assertEqual(self.request(method,'/executions',headers={'Origin':'https://example.com'})[0],403)
            self.assertEqual(self.request(method,'/executions',headers={'Host':'example.com'})[0],403)
            self.peer = '192.0.2.20'

    def test_plain_error_and_buffered_thinking_preserved(self):
        self.peer='127.0.0.1'
        self.state.policy.escalate_below = 1
        reply={'model':'test-model','choices':[{'message':{'content':'Answer','reasoning':'Thinking'},'finish_reason':'stop'}]}
        with patch('dyno.router.server._post',return_value=reply):
            self.request('POST','/v1/chat/completions',{'messages':[{'role':'user','content':'Hello'}]})
        row=json.loads(self.request('GET','/executions')[2])['executions'][0]
        trace=json.loads(self.request('GET','/executions/'+row['id'])[2])
        self.assertEqual([e['kind'] for e in trace['events']][-2:],['thinking','output'])
        self.state.backends=lambda: []
        self.assertEqual(self.request('POST','/v1/chat/completions',{'model':'missing'})[0],503)
        row=json.loads(self.request('GET','/executions')[2])['executions'][0]
        self.assertEqual(row['status'],'failed')

if __name__ == '__main__':
    unittest.main()

class HistoryCleanupTests(unittest.TestCase):
    def test_parser_failure_does_not_strand_active_record(self):
        import io
        from unittest.mock import patch
        from dyno.execution import ExecutionHTTPMixin, current_execution
        class Base:
            def do_POST(self):
                pass
        class Handler(ExecutionHTTPMixin, Base):
            pass
        handler = Handler()
        handler.path = '/v1/chat/completions'
        handler.headers = {}
        handler.rfile = io.BytesIO()
        handler.wfile = io.BytesIO()
        original_reader, original_writer = handler.rfile, handler.wfile
        handler.execution_store = ExecutionStore(capacity=1)
        with patch('dyno.execution.ResponseCapture.finish', side_effect=ValueError('bad response')):
            with self.assertRaises(ValueError):
                handler.do_POST()
        self.assertEqual(handler.execution_store.snapshot()['executions'][0]['status'], 'completed')
        self.assertIs(handler.rfile, original_reader)
        self.assertIs(handler.wfile, original_writer)
        self.assertIsNone(current_execution())
        self.assertIsNotNone(handler.execution_store.begin('/v1/chat/completions'))
