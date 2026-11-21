"""Minimal fake Kubernetes API for the reporter repro.

Serves GET /api/v1/namespaces/<ns>/pods over TLS on :443 with a valid PodList
JSON body of exactly TARGET bytes (argv[1]), so we can see at which body size
the lab image's reporter stops parsing the response.
"""
import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TARGET = int(sys.argv[1])


def podlist(pad: int) -> bytes:
    doc = {
        "kind": "PodList",
        "apiVersion": "v1",
        "metadata": {},
        "items": [{
            "metadata": {"name": "p0", "namespace": "test", "annotations": {"pad": "x" * pad}},
            "status": {"phase": "Running"},
        }],
    }
    return json.dumps(doc, separators=(",", ":")).encode()


BASE = len(podlist(0))
if TARGET < BASE:
    sys.exit(f"target must be >= {BASE} bytes")
BODY = podlist(TARGET - BASE)
assert len(BODY) == TARGET


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


server = HTTPServer(("0.0.0.0", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/w/cert.pem", "/w/key.pem")
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
