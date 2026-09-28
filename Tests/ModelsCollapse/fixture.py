"""Fresh synthetic sidebar fixture, listening only on loopback."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODELS = [{"id": f"demo-{i}", "name": name, "owned_by": "openai"}
          for i, name in enumerate(["Paper Planner", "Kite Designer", "Harbor Guide"])]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        route = urlsplit(self.path)
        path, args = route.path.rstrip("/"), parse_qs(route.query)
        value = []
        if path in ("", "/health"):
            value = {"status": True}
        elif path == "/api/config":
            value = {"status": True, "version": "0.0.0-search-fixture", "name": "Paper Workshop",
                     "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                  "enable_websocket": False, "enable_channels": False},
                     "default_models": [MODELS[0]["id"]]}
        elif path == "/api/version":
            value = {"version": "0.0.0-search-fixture"}
        elif path == "/api/v1/auths/signin":
            value = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
        elif path == "/api/v1/auths":
            value = USER
        elif path == "/api/models":
            value = {"data": MODELS}
        elif path == "/api/v1/models/model":
            value = next((m for m in MODELS if m["id"] == args.get("id", [""])[0]), MODELS[0])
        elif path == "/api/v1/users/user/settings":
            value = {"ui": {"models": [MODELS[0]["id"]], "pinnedModels": [m["id"] for m in MODELS]}}
        elif path == "/api/v1/folders":
            value = [{"id": "crafts", "name": "Paper crafts", "parent_id": None, "is_expanded": False, "data": {}, "meta": {}}]
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.do_GET()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
