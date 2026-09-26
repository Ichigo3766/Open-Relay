"""Loopback-only, invented prompts; never reads a database or contacts a model."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROMPTS = [
    {"title": ["Paper garden", "Plan a colorful craft"], "content": "Plan a paper flower craft."},
    {"title": ["Cloud shapes", "Invent a small story"], "content": "Write a story about cloud shapes."},
    {"title": ["Puzzle time", "Try a number puzzle"], "content": "Invent a simple number puzzle."},
    {"title": ["Star map", "Learn about constellations"], "content": "Explain a fictional constellation."},
]


class Handler(BaseHTTPRequestHandler):
    source = "admin"
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
                    "features": {"enable_websocket": False},
                    "default_prompt_suggestions": PROMPTS if self.source == "admin" else []}
        elif path == "/api/version":
            data = {"version": "0.0.0"}
        elif path == "/api/v1/auths":
            data = {"id": "demo", "name": "Demo", "email": "demo@example.test", "role": "admin"}
        elif path == "/api/v1/users/user/settings":
            data = {"ui": {"models": ["demo"], "memory": True}}
        elif path in ("/api/models", "/api/v1/models"):
            data = {"data": [{"id": "demo", "name": "Demo", "owned_by": "demo",
                              "info": {"meta": {"suggestion_prompts": PROMPTS if self.source == "model" else []}}}]}
        elif path == "/qa/state":
            data = {"writes": self.writes}
        self.respond(data)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if self.path == "/qa/reset":
            Handler.source = data.get("source", "admin")
            Handler.writes = 0
        else:
            Handler.writes += 1
        self.respond({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18194), Handler).serve_forever()
