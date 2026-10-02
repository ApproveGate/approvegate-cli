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
  /mode/allowdetails -> 200 allow with the optional `details` object and code ALLOW
  /mode/blockpending -> 200 block, code PENDING, with `details` for a pending approval

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

    def do_GET(self):
        if "/actions/runs/" in self.path and self.path.endswith("/jobs?per_page=100"):
            resp = {
                "jobs": [
                    {
                        "name": "unit-tests",
                        "status": "completed",
                        "conclusion": "success",
                        "html_url": "https://github.com/acme/ledger/actions/runs/1/job/10",
                    },
                    {
                        "name": "security-scan",
                        "status": "completed",
                        "conclusion": "success",
                        "html_url": "https://github.com/acme/ledger/actions/runs/1/job/11",
                    },
                    {
                        "name": "deploy",
                        "status": "in_progress",
                        "conclusion": None,
                        "html_url": "https://github.com/acme/ledger/actions/runs/1/job/12",
                    },
                ]
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return

        self.send_response(404)
        self.end_headers()

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

        if mode in ("allowdetails", "blockpending"):
            pending = mode == "blockpending"
            resp = {
                "decision": "block" if pending else "allow",
                "code": "PENDING" if pending else "ALLOW",
                "reason": "Release request is pending approval." if pending else "Approved and artifact matches bound SHA.",
                "releaseRequestUrl": "http://localhost:3000/app/acme-pay/release-requests/approval-123",
                "details": {
                    "artifactSha": "9f2a1c4e7b0d11223344556677889900aa83c17b",
                    "approval": {
                        "status": "PENDING" if pending else "APPROVED",
                        "release": "v1.1.0",
                        "branch": None,
                        "ticketRef": "CHG-4471",
                        "approverEmail": None if pending else "maya.chen@acmepay.com",
                        "requesterEmail": "jordan.doe@acmepay.com",
                        "validUntil": None if pending else "2026-10-08T14:38:00.000Z",
                    },
                    "sod": {"mode": "ENFORCING", "satisfied": True, "requester": "jordan.doe", "approver": None if pending else "maya.chen"},
                    "freeze": {"active": False, "windowReason": None, "overridden": False},
                },
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return

        if mode == "block":
            resp = {"decision": "block", "reason": "No deploy authorization recorded for release."}
        else:
            resp = {
                "decision": "allow",
                "reason": "Approved and artifact matches bound SHA.",
                "links": {"releaseRequest": "http://localhost:3000/app/acme-corp-1/release-requests/approval-123"},
            }

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
