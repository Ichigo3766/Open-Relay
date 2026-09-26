"""In-memory loopback fixture; no real server, database, credentials, or chats."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    settings = {"ui": {"models": ["demo-calm"], "memory": True, "pinnedModels": ["demo-vision"]}}
    writes = 0

    def log_message(self, *_):
        pass

    def respond(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip("/")
        result = []
        if path == "/health":
            result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "name": "Demo", "version": "0.0.0", "features": {"enable_websocket": False}}
        elif path == "/api/version":
            result = {"version": "0.0.0"}
        elif path == "/api/v1/auths":
            result = {"id": "demo", "name": "Demo", "email": "demo@example.test", "role": "admin"}
        elif path == "/api/v1/users/user/settings":
            result = Handler.settings
        elif path == "/qa/state":
            result = {"settings": Handler.settings, "writes": Handler.writes}
        elif path in ("/api/models", "/api/v1/models"):
            result = {"data": [
                {"id": "demo-calm", "name": "Calm", "owned_by": "demo"},
                {"id": "demo-orbit", "name": "Orbit", "owned_by": "demo"},
                {"id": "demo-vision", "name": "Prism", "owned_by": "demo", "info": {"meta": {"capabilities": {"vision": True}}}},
            ]}
        self.respond(result)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if self.path.rstrip("/") == "/api/v1/users/user/settings/update":
            Handler.settings.update(data)
            Handler.writes += 1
        elif self.path == "/qa/reset":
            Handler.settings = {"ui": {"models": ["demo-calm"], "memory": True, "pinnedModels": ["demo-vision"]}}
            Handler.writes = 0
        self.respond(Handler.settings)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18193), Handler).serve_forever()
