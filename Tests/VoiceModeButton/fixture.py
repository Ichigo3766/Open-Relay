"""Loopback-only fixture. No database, credentials, real chats, or model calls."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    writes = 0

    def log_message(self, *_):
        pass

    def respond(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        data = []
        if path == "/api/config":
            data = {"status": True, "name": "Demo", "version": "0.0.0",
                    "features": {"enable_websocket": False, "enable_web_search": True}}
        elif path == "/api/version":
            data = {"version": "0.0.0"}
        elif path == "/api/v1/users/user/settings":
            data = {"ui": {"models": ["demo"]}}
        elif path in ("/api/models", "/api/v1/models"):
            data = {"data": [{"id": "demo", "name": "Demo", "owned_by": "demo"}]}
        elif path == "/qa/state":
            data = {"writes": self.writes}
        self.respond(data)

    def do_POST(self):
        if self.path == "/qa/reset":
            Handler.writes = 0
        else:
            Handler.writes += 1
        self.respond({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18196), Handler).serve_forever()
