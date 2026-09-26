"""Synthetic loopback-only library; no credentials or stored chat data."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        data = []
        if path == "/api/config":
            data = {"status": True, "name": "Demo", "version": "0.0.0",
                    "features": {"enable_websocket": False}}
        elif path == "/api/version":
            data = {"version": "0.0.0"}
        elif path == "/api/v1/users/user/settings":
            data = {"ui": {"models": ["demo"]}}
        elif path in ("/api/models", "/api/v1/models"):
            data = {"data": [{"id": "demo", "name": "Demo", "owned_by": "demo"}]}
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18201), Handler).serve_forever()
