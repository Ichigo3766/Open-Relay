"""Invented in-memory data; never reads a database or contacts a server/model."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    scenario = {}

    def log_message(self, *_):
        pass

    def respond(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        data = []
        if path == "/api/config":
            data = {"status": True, "name": "Demo", "version": "0.0.0",
                    "features": {"enable_websocket": False,
                                 "enable_channels": self.scenario.get("channels", False)}}
        elif path == "/api/version":
            data = {"version": "0.0.0"}
        elif path == "/api/v1/users/user/settings":
            data = {"ui": {"models": ["demo"]}}
        elif path in ("/api/models", "/api/v1/models"):
            data = {"data": [{"id": "demo", "name": "Demo", "owned_by": "demo"}]}
        elif path == "/api/v1/folders":
            if self.scenario.get("foldersForbidden"):
                return self.respond({"detail": "Unavailable"}, 403)
            if not self.scenario.get("emptyFolders"):
                data = [{"id": "paper", "name": "Paper crafts", "items": [], "is_expanded": False}]
        elif path == "/api/v1/folders/shared" and self.scenario.get("shared"):
            data = [{"id": "shared", "name": "Shared crafts", "items": []}]
        elif path == "/api/v1/chats" and not self.scenario.get("emptyChats"):
            data = [{"id": "cloud", "title": "Cloud shapes", "updated_at": 1700000000,
                     "created_at": 1700000000, "folder_id": None, "pinned": False}]
        self.respond(data)

    def do_POST(self):
        if self.path != "/qa/scenario":
            return self.respond({"detail": "Read-only fixture"}, 405)
        Handler.scenario = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.respond({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18195), Handler).serve_forever()
