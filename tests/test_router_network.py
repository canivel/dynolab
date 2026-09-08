"""Exercise shared HTTP endpoints without loading MLX or model weights."""
import http.client
import io
import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from dyno.router.backends import Backend
from dyno.router.policy import Policy
from dyno.router.server import RouterHandler, RouterState


class NetworkSharingTests(unittest.TestCase):
    def setUp(self):
        self.state = RouterState(Policy(self_routing=False, escalate_below=0), (), [], False)
        backend = Backend("http://127.0.0.1:8971", "test-model", "test-model", 8971)
        self.state.backends = lambda: [backend]
        self.peer = "192.0.2.20"
        owner = self

        class Handler(RouterHandler):
            state = owner.state

            def setup(self):
                super().setup()
                # Real HTTP parsing/transport, with a deterministic socket peer.
                self.client_address = (owner.peer, self.client_address[1])

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        connection.request(method, path, json.dumps(body) if body else None, headers or {})
        response = connection.getresponse()
        result = (response.status, dict(response.getheaders()), response.read())
        connection.close()
        return result

    def test_remote_model_discovery(self):
        status, _, body = self.request("GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual([m["id"] for m in json.loads(body)["data"]], ["auto", "test-model"])

    def test_remote_admin_denied_even_with_forwarded_loopback(self):
        for path in ("/config", "/routes", "/v1/routes", "/backends", "/metrics"):
            with self.subTest(path=path):
                self.assertEqual(self.request("GET", path + "?test=1", headers={
                    "X-Forwarded-For": "127.0.0.1"
                })[0], 403)
        self.assertEqual(self.request("POST", "/config", {"self_routing": True})[0], 403)
        self.assertFalse(self.state.policy.self_routing)

    def test_local_administration_still_works(self):
        self.peer = "127.0.0.1"
        for path in ("/config", "/routes", "/v1/routes", "/backends", "/metrics"):
            self.assertEqual(self.request("GET", path)[0], 200)
        self.assertEqual(self.request("POST", "/config", {"self_routing": True})[0], 200)
        self.assertTrue(self.state.policy.self_routing)

    def test_remote_inference_auto_and_named_model(self):
        reply = {"model": "test-model", "choices": [{"message": {"content": "hello"}}]}
        with patch("dyno.router.server._post", return_value=reply) as upstream:
            for model in ("auto", "test-model"):
                status, _, body = self.request("POST", "/v1/chat/completions", {
                    "model": model, "messages": [{"role": "user", "content": "Hello"}]
                })
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body), reply)
                self.assertEqual(upstream.call_args.args[1]["model"], "test-model")

    def test_remote_streaming(self):
        stream = b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'
        with patch("dyno.router.server._post_stream", return_value=io.BytesIO(stream)):
            status, headers, body = self.request("POST", "/v1/chat/completions", {
                "model": "auto", "messages": [{"role": "user", "content": "Hello"}],
                "stream": True,
            })
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/event-stream")
        self.assertEqual(body, stream)
        self.assertEqual(headers["Access-Control-Allow-Origin"], "*")

    def test_browser_preflight_accepts_sdk_authorization_header(self):
        status, headers, _ = self.request("OPTIONS", "/v1/chat/completions")
        self.assertEqual(status, 204)
        self.assertIn("Authorization", headers["Access-Control-Allow-Headers"])


if __name__ == "__main__":
    unittest.main()
