#!/usr/bin/env python3
"""Stand-in for Prometheus' HTTP API, for tests/test-panel.sh.

    prometheus-stub.py PORT DIR

Answers GET /api/v1/query with DIR/query.json and GET /api/v1/alerts with
DIR/alerts.json (status 200), so a test can change the answer between
requests by rewriting the files. A missing file is a 503. Every request line
is appended to DIR/requests.log.
"""
import http.server
import os
import socketserver
import sys

port, root = int(sys.argv[1]), sys.argv[2]


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with open(os.path.join(root, "requests.log"), "a", encoding="utf-8") as f:
            f.write(self.path + "\n")
        name = {"/api/v1/query": "query.json", "/api/v1/alerts": "alerts.json"}.get(self.path.split("?")[0])
        try:
            with open(os.path.join(root, name or "-"), "rb") as f:
                body, code = f.read(), 200
        except OSError:
            body, code = b'{"status":"error"}', 503
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class S(http.server.ThreadingHTTPServer):
    def server_bind(self):  # skip the DNS lookup of HTTPServer.server_bind
        socketserver.TCPServer.server_bind(self)


S(("127.0.0.1", port), H).serve_forever()
