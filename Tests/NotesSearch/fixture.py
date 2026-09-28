"""Fresh synthetic notes served only on loopback; no real instance or files."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "notes-demo", "name": "Notes Search Demo", "owned_by": "openai"}
CALLS = []


def note(identifier, title):
    content = "Overview of the demo collection." if identifier == "index" else "An invented paper-star catalog entry."
    return {"id": identifier, "title": title, "data": {"content": {"md": content}},
            "created_at": 1780000000000000000, "updated_at": 1780000000000000000}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        route = urlsplit(self.path)
        path, query = route.path.rstrip("/"), parse_qs(route.query)
        result = []
        if path == "/_test/state": result = CALLS
        elif path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-notes-fixture", "name": "Notes Search Demo",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": False, "enable_notes": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-notes-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/notes": result = [note("index", "Catalog Index")]
        elif path == "/api/v1/notes/search":
            page = int(query.get("page", ["1"])[0])
            text = query.get("query", [""])[0]
            CALLS.append({"query": text, "page": page})
            # Small pages deliberately verify the client does not hard-code a page size.
            matches = [note(f"star-{n}", f"Paper Star {n}") for n in range(1, 4)] if text == "paper" else []
            result = {"items": matches[(page - 1) * 2:page * 2], "total": len(matches)}
        elif path.startswith("/api/v1/notes/"): result = note(path.split("/")[-1], "Paper Star")
        self.reply(result)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/_test/reset": CALLS.clear()
        self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"} if self.path.rstrip("/") == "/api/v1/auths/signin" else {})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
