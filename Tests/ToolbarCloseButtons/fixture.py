"""Read-only, empty synthetic library. No access to an actual server or database."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip("/")
        result = []
        if path in ("/health", ""):
            result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "name": "Demo", "version": "0.0.0",
                      "features": {"enable_websocket": False, "enable_notes": True,
                                   "enable_channels": True, "enable_memories": True}}
        elif path == "/api/version":
            result = {"version": "0.0.0"}
        elif path == "/api/v1/auths":
            result = {"id": "demo", "name": "Demo", "email": "demo@example.test", "role": "admin"}
        elif path == "/api/v1/users/user/settings":
            result = {"ui": {"memory": True}}
        elif path in ("/api/models", "/api/v1/models"):
            result = {"data": []}
        elif path in ("/api/v1/users", "/api/v1/automations/list"):
            result = {"items": [], "users": [], "total": 0}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18192), Handler).serve_forever()
