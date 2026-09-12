#!/usr/bin/env python3
"""Minimal stdlib-only mock of POST /api/v1/checks for testing check.sh.

The response mode is selected by URL path suffix (e.g. http://host:port/mode/allow)
so tests can point APPROVEGATE_API_URL at a specific canned behavior without any
extra flags on check.sh itself.

Modes:
  /mode/allow       -> 200 {"decision": "allow", "reason": "..."}
  /mode/block       -> 200 {"decision": "block", "reason": "..."}
  /mode/force       -> 200 allow if the request body has forceApprove: true, else block
  /mode/servererror -> 500 plain text (exercises the "unreachable" 5xx path)
  /mode/malformed   -> 200 body that isn't valid JSON
  /mode/hang        -> sleeps 5s before responding (exercises the timeout path)

If REQUEST_LOG_FILE is set in the environment, each request's JSON body is
appended to that file as one line, so tests can assert what was actually sent.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

REQUEST_LOG_FILE = os.environ.get("REQUEST_LOG_FILE")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output quiet

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) if length else b""

        if REQUEST_LOG_FILE:
            with open(REQUEST_LOG_FILE, "a") as f:
                f.write(raw_body.decode("utf-8", errors="replace") + "\n")

        mode = self.path.rsplit("/", 1)[-1]

        if mode == "servererror":
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"internal error")
            return

        if mode == "malformed":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"not json")
            return

        if mode == "hang":
            time.sleep(5)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({"decision": "allow", "reason": "slow"}).encode())
            return

        if mode == "force":
            try:
                body = json.loads(raw_body or b"{}")
            except json.JSONDecodeError:
                body = {}
            if body.get("forceApprove") is True:
                resp = {"decision": "allow", "reason": body.get("reason") or "Force-approved override."}
            else:
                resp = {"decision": "block", "reason": "No deploy authorization recorded."}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return

        if mode == "block":
            resp = {"decision": "block", "reason": "No deploy authorization recorded for release."}
        else:
            resp = {"decision": "allow", "reason": "Approved and artifact matches bound SHA."}

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(resp).encode())


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = HTTPServer(("127.0.0.1", port), Handler)
    # Print the bound port so callers can use port 0 (auto-assign) safely.
    print(server.server_address[1], flush=True)
    server.serve_forever()
