"""Synthetic note pin state, isolated on loopback. No private instance or content."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "notes-demo", "name": "Note Pins Demo", "owned_by": "openai"}
PINNED = True
FAIL = False
CALLS = 0


def note():
    return {"id": "paper-stars", "title": "Paper Stars", "is_pinned": PINNED,
            "data": {"content": {"md": "An invented folding checklist."}},
            "created_at": 1780000000000000000, "updated_at": 1780000000000000000}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip("/")
        result = []
        if path == "/_test/state": result = {"pinned": PINNED, "calls": CALLS}
        elif path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-note-pins-fixture", "name": "Note Pins Demo",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": False, "enable_notes": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-note-pins-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/notes": result = [note()]
        elif path == "/api/v1/notes/paper-stars": result = note()
        self.reply(result)

    def do_POST(self):
        global PINNED, FAIL, CALLS
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/_test/reset":
            PINNED = True; FAIL = False; CALLS = 0
        elif path == "/_test/fail": FAIL = True
        elif path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        elif path == "/api/v1/notes/paper-stars/pin":
            if self.headers.get("Authorization") != "Bearer synthetic-token":
                return self.reply({"detail": "Unauthorized"}, 401)
            CALLS += 1
            if FAIL: return self.reply({"detail": "Synthetic pin failure"}, 503)
            PINNED = not PINNED
            return self.reply(note())
        self.reply({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
