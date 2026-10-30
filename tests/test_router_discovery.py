"""A scanning router must not discover itself (or another router) as a model server.

It used to: its port is in the scan range, its /v1/models runs discovery, and discovery probed it again, so one
request started a chain of requests to itself that never ended (a steady ~22% CPU and endless broken pipes).
"""
import json
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from dyno.router import backends
from dyno.router.policy import Policy
from dyno.router.server import RouterHandler, RouterState


class Router:
    """A real router on a free port, counting the requests it answers."""

    def __init__(self, scan_ports=()):
        self.requests = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), None)
        self.port = self.server.server_address[1]
        self.state = RouterState(Policy(), tuple(scan_ports) or (self.port,), [], scan=True, own_port=self.port)
        owner = self

        class Handler(RouterHandler):
            state = owner.state

            def handle_one_request(self):
                owner.requests += 1
                super().handle_one_request()

        self.server.RequestHandlerClass = Handler
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as response:
            return json.load(response)

    def close(self):
        self.server.shutdown(); self.server.server_close()


class SelfDiscovery(unittest.TestCase):
    def setUp(self):
        # lsof/ps identification isn't what's under test, and is slow; the HTTP probes are real.
        patcher = patch.object(backends, "_model_from_process", lambda port: None)
        patcher.start(); self.addCleanup(patcher.stop)

    def test_a_router_does_not_probe_itself(self):
        router = Router(); self.addCleanup(router.close)
        start = time.monotonic()
        models = router.get("/v1/models")
        self.assertLess(time.monotonic() - start, 1.0)
        self.assertEqual([m["id"] for m in models["data"]], ["auto"])
        self.assertTrue(models["dyno_router"])
        time.sleep(1.0)
        self.assertEqual(router.requests, 1)  # only ours: nothing it sent to itself

    def test_two_routers_do_not_take_each_other_for_backends(self):
        first = Router(); self.addCleanup(first.close)
        second = Router(scan_ports=(first.port,)); self.addCleanup(second.close)
        first.state.ports = (first.port, second.port)
        self.assertEqual(second.get("/backends")["backends"], [])
        self.assertEqual(first.get("/backends")["backends"], [])
        time.sleep(1.0)
        # Ours (2), and each way one port check plus one /stats: neither ran discovery for the other.
        self.assertLessEqual(first.requests + second.requests, 6)


class Caching(unittest.TestCase):
    def test_an_empty_result_is_reused_for_a_few_seconds(self):
        calls = []
        with patch("dyno.router.server.discover", lambda *a, **k: calls.append(1) or []):
            state = RouterState(Policy(), (9,), [], scan=True, own_port=8970)
            for _ in range(5): state.backends()
            self.assertEqual(len(calls), 1)
            state.backends(force=True)
            self.assertEqual(len(calls), 2)

    def test_own_port_is_excluded_from_the_scan(self):
        seen = {}
        with patch("dyno.router.server.discover", lambda ports, extra, scan, exclude: seen.update(exclude=exclude) or []):
            RouterState(Policy(), (8970, 8971), [], scan=True, own_port=8970).backends()
        self.assertEqual(seen["exclude"], {8970})


if __name__ == "__main__":
    unittest.main()
