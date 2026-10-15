#!/usr/bin/env python3
"""Disposable Forgejo-API-shaped HTTP server for driving fm-pr-merge.sh live.

The scenario is read per request from <labdir>/mode so one server serves every
scenario. Every request is appended to <labdir>/requests.log.
  page2-http-error : status page 2 answers HTTP 500 with a Forgejo error object
  page2-http-404   : status page 2 answers HTTP 404 with a Forgejo error object
  page2-empty-null : status page 2 is the real empty combined status (statuses null)
  page1-http-error : status page 1 answers HTTP 500 with a Forgejo error object
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

LAB = sys.argv[1]
PORT = int(sys.argv[2])
OWNER, REPO, NUM = "labowner", "labrepo", "9"
HEAD = "c" * 40


def mode():
    with open(f"{LAB}/mode") as f:
        return f.read().strip()


def merged():
    try:
        open(f"{LAB}/merged").close()
        return True
    except FileNotFoundError:
        return False


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json;charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, code, msg):
        self.send(code, {"errors": None, "message": msg,
                         "url": f"http://127.0.0.1:{PORT}/api/swagger"})

    def handle_any(self, method):
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        with open(f"{LAB}/requests.log", "a") as f:
            f.write(f"{mode()} {method} {self.path}\n")
        base = f"/api/v1/repos/{OWNER}/{REPO}"
        p = u.path
        if p == "/api/v1/version":
            return self.send(200, {"version": "11.0.0+gitea-1.22.0"})
        if p == "/api/v1/user":
            return self.send(200, {"id": 1, "login": "lab", "username": "lab"})
        if p == base and method == "GET":
            return self.send(200, {"name": REPO, "default_merge_style": "merge"})
        if p == f"{base}/pulls/{NUM}" and method == "GET":
            if merged():
                return self.send(200, {"number": 9, "state": "closed", "merged": True,
                                       "mergeable": False, "draft": False,
                                       "merge_commit_sha": "e" * 40,
                                       "head": {"sha": HEAD}})
            return self.send(200, {"number": 9, "state": "open", "merged": False,
                                   "mergeable": True, "draft": False,
                                   "head": {"sha": HEAD}})
        if p == f"{base}/pulls/{NUM}/merge" and method == "POST":
            open(f"{LAB}/merged", "w").close()
            n = int(self.headers.get("Content-Length") or 0)
            with open(f"{LAB}/merge-body", "w") as f:
                f.write(self.rfile.read(n).decode())
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if p == f"{base}/commits/{HEAD}/status":
            page = int(q.get("page", ["1"])[0])
            m = mode()
            if page == 1 and m == "page1-http-error":
                return self.err(500, "internal server error")
            if page == 1:
                return self.send(200, {"state": "success", "sha": HEAD, "total_count": 1,
                                       "statuses": [{"context": "ci/build", "status": "success"}]})
            if page == 2 and m == "page2-http-error":
                return self.err(500, "internal server error")
            if page == 2 and m == "page2-http-404":
                return self.err(404, "Not Found")
            return self.send(200, {"state": "", "sha": "", "total_count": 0, "statuses": None,
                                   "repository": None, "commit_url": "", "url": ""})
        return self.err(404, "Not Found")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
