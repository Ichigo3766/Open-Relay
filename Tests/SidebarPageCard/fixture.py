"""Loopback-only, invented completed chats. No external service or saved data."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

USER = {"id": "demo", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture", "name": "Fixture Model", "owned_by": "openai"}
CHATS = {}
for index, title in enumerate(("Paper garden", "Lighthouse sketch")):
    identifier = f"synthetic-{index}"
    heading = "A paper garden" if index == 0 else "An imaginary lighthouse"
    question = {"id": "question", "role": "user", "content": "Describe an imaginary paper garden.",
                "parentId": None, "childrenIds": ["answer"], "timestamp": 1700000000}
    answer = {"id": "answer", "role": "assistant", "parentId": "question", "childrenIds": [],
              "timestamp": 1700000001, "model": "fixture", "done": True,
              "content": f"# {heading}\n\n" + "\n\n".join(
                  f"**Sketch {n}**\n\nFold a blue paper leaf beside a yellow flower. A tiny wooden bridge crosses an imaginary stream. These are invented notes for a visual test."
                  for n in range(1, 9))}
    chat = {"id": identifier, "title": title, "models": ["fixture"],
            "history": {"currentId": "answer", "messages": {"question": question, "answer": answer}},
            "messages": [question, answer]}
    CHATS[identifier] = {"id": identifier, "title": title, "user_id": "demo", "chat": chat,
                         "created_at": 1700000000 + index, "updated_at": 1700000000 + index,
                         "pinned": False, "archived": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        route = urlsplit(self.path)
        path = route.path.rstrip("/")
        result = []
        if path in ("", "/health"):
            result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-fixture", "name": "Synthetic Sidebar",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False}, "default_models": ["fixture"]}
        elif path == "/api/version":
            result = {"version": "0.0.0-fixture"}
        elif path == "/api/v1/auths":
            result = USER
        elif path == "/api/v1/auths/signin":
            result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
        elif path == "/api/models":
            result = {"data": [MODEL]}
        elif path.startswith("/api/v1/models/model"):
            result = MODEL
        elif path == "/api/v1/users/user/settings":
            result = {"ui": {}}
        elif path in ("/api/v1/chats", "/api/v1/chats/list"):
            result = [{k: v for k, v in chat.items() if k != "chat"} for chat in CHATS.values()] if parse_qs(route.query).get("page", ["1"]) == ["1"] else []
        elif path.startswith("/api/v1/chats/"):
            result = CHATS.get(path.split("/")[4], [])
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.do_GET()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18189), Handler).serve_forever()
