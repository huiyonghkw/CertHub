#!/usr/bin/env python3
"""CertHub Community read-only health endpoint."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return

        payload = json.dumps(
            {
                "status": "ok",
                "service": "certhub-community",
                "edition": "community",
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, message, *args):
        print("health: " + message % args, flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("CERTHUB_HEALTH_PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), HealthHandler).serve_forever()
