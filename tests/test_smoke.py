#!/usr/bin/env python3
"""CertHub Community smoke tests."""

from __future__ import annotations

import importlib.util
import json
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "web" / "health_server.py"
SPEC = importlib.util.spec_from_file_location("health_server", MODULE_PATH)
health_server = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(health_server)


class HealthEndpointTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = health_server.ThreadingHTTPServer(
            ("127.0.0.1", 0), health_server.HealthHandler
        )
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, path):
        import urllib.error
        import urllib.request

        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{self.server.server_port}{path}", timeout=2
            ) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def test_health(self):
        status, body = self.request("/health")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["edition"], "community")

    def test_management_routes_are_absent(self):
        for path in ("/", "/api/dashboard", "/api/certificates", "/api/config"):
            status, _ = self.request(path)
            self.assertEqual(status, 404, path)


if __name__ == "__main__":
    unittest.main()
