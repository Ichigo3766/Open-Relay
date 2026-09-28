"""Fresh invented model/channel fixture, loopback only. No media or external calls."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "notes-demo", "name": "Toolbar Demo", "owned_by": "openai"}
CHANNEL = {"id": "demo-room", "user_id": "demo-user", "name": "Demo Channel",
           "type": "standard", "write_access": True, "created_at": 1780000000,
           "updated_at": 1780000000}


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
        path = urlsplit(self.path).path.rstrip("/")
        result = []
        if path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-picker-fixture", "name": "Picker Demo",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-picker-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path in ("/api/v1/channels", "/api/v1/channels/list"): result = [CHANNEL]
        elif path == "/api/v1/channels/demo-room": result = CHANNEL
        self.reply(result)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        result = {}
        if urlsplit(self.path).path.rstrip("/") == "/api/v1/auths/signin":
            result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
        self.reply(result)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
