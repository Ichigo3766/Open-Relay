"""Invented note access fixture. No personal data or external services."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "notes-demo", "name": "Notes Access Demo", "owned_by": "openai"}
WRITE = False
UPDATES = []


def note():
    result = {"id": "paper", "title": "Paper Lanterns", "user_id": "demo-author",
              "data": {"content": {"md": "# Folding checklist\n\nUse a square sheet. Fold the edges inward.\n\nThis shared note is available to read."}},
              "created_at": 1780000000000000000, "updated_at": 1780000000000000000}
    if WRITE is not None:
        result["write_access"] = WRITE
    return result


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
        if path == "/_test/state": result = {"updates": UPDATES}
        elif path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-note-access-fixture", "name": "Notes Access Demo",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": False, "enable_notes": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-note-access-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/notes": result = [note()]
        elif path == "/api/v1/notes/paper": result = note()
        self.reply(result)

    def do_POST(self):
        global WRITE, UPDATES
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/_test/reset": WRITE = False; UPDATES = []
        elif path == "/_test/writable": WRITE = True
        elif path == "/_test/legacy": WRITE = None
        elif path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        elif path == "/api/v1/notes/paper/update":
            if self.headers.get("Authorization") != "Bearer synthetic-token":
                return self.reply({"detail": "Unauthorized"}, 401)
            UPDATES.append(body)
            if WRITE is False: return self.reply({"detail": "Read-only note"}, 403)
            return self.reply(note())
        self.reply({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
