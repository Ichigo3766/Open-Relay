"""Loopback-only, invented chat fixtures; never accesses a real account/server."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

USER = {"id": "spacing-fixture", "name": "Demo", "email": "demo@example.test", "role": "admin"}
REPLY = """Build a small paper observatory. Here are three steps:

1. Fold a square of blue paper into a sturdy base. Leave one side open so the roof can be attached later.
2. Cut a round window from yellow paper and place it near the center of the front wall.
3. Add a silver roof and a small cardboard telescope. Use a paper star as the finishing touch.

Place the finished model on a level shelf. Keep the remaining paper in a box for the next workshop."""

def make_chat(suffix, turns, reply):
    chat_id = "00000000-0000-4000-8000-00000000000" + suffix
    messages = {}
    for i in range(turns):
        question, answer = f"q{i}", f"a{i}"
        messages[question] = {"id": question, "role": "user", "content": "Plan a paper observatory." if i == turns - 1 else f"Describe craft station {i + 1}.", "parentId": f"a{i - 1}" if i else None, "childrenIds": [answer], "models": ["fixture"], "timestamp": 1700000000 + i * 2}
        messages[answer] = {"id": answer, "role": "assistant", "content": reply if i == turns - 1 else ("Set out paper, pencils, and glue. " * 24), "parentId": question, "childrenIds": [f"q{i + 1}"] if i < turns - 1 else [], "model": "fixture", "done": True, "timestamp": 1700000001 + i * 2}
    return {"id": chat_id, "title": "Paper observatory " + suffix, "user_id": USER["id"], "created_at": 1700000000, "updated_at": 1700000200, "pinned": False, "archived": False, "chat": {"id": chat_id, "title": "Paper observatory " + suffix, "models": ["fixture"], "params": {}, "history": {"messages": messages, "currentId": f"a{turns - 1}"}, "messages": list(messages.values())}}

CHATS = {chat["id"]: chat for chat in [make_chat("1", 8, REPLY), make_chat("2", 8, REPLY * 5), make_chat("3", 1, "Fold the paper and add a star.")]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path.rstrip("/")
        if path in ("", "/health"):
            return self.send({"status": True})
        if path == "/api/config":
            return self.send({"status": True, "version": "0.0.0-fixture", "name": "Fixture", "features": {"auth": True, "enable_login_form": True, "enable_signup": False, "enable_websocket": False}, "default_models": ["fixture"]})
        if path == "/api/version":
            return self.send({"version": "0.0.0-fixture"})
        if path == "/api/v1/auths":
            return self.send(USER)
        if path == "/api/models":
            return self.send({"data": [{"id": "fixture", "name": "Fixture Model", "owned_by": "openai"}]})
        if path == "/api/v1/chats":
            return self.send([{k: v for k, v in c.items() if k != "chat"} for c in CHATS.values()] if parse_qs(url.query).get("page", ["1"])[0] == "1" else [])
        if path.startswith("/api/v1/chats/") and path.rsplit("/", 1)[-1] in CHATS:
            return self.send(CHATS[path.rsplit("/", 1)[-1]])
        if path == "/api/v1/users/user/settings":
            return self.send({"ui": {}})
        if path == "/api/v1/users/user/permissions":
            return self.send({"chat": {"file_upload": True}})
        if path.startswith(("/ws", "/socket.io")):
            return self.send({}, 404)
        return self.send([])

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/api/v1/auths/signin":
            return self.send({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        if path.endswith("/read"):
            return self.send(True)
        return self.send({"detail": "Read-only fixture"}, 405)

if __name__ == "__main__":
    print("Synthetic spacing fixture listening on 127.0.0.1:18089", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18089), Handler).serve_forever()
