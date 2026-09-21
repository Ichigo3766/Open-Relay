"""Loopback-only, in-memory fixture for message action UI checks.

Run with python3 Tests/MessageActionPreferences/mock_server.py. All data is
invented. No Open WebUI code, account, instance, or network service is used.
POST /fixture changes permissions, rating_enabled, text, or versions;
GET /fixture reports every app write so local settings can be checked for leaks.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CHAT_ID = "b7185907-9171-4c49-ab9d-d5a12d201237"
TEXT = "Text + spaces & symbols = 100% #ready?\nUnicode: café 日本語 🪁\nhttps://example.test/?a=1&b=2"
STATE = {"permissions": {}, "rating_enabled": True, "text": TEXT, "versions": True, "writes": []}


def user():
    return {"id": "synthetic-user", "name": "Demo", "email": "demo@example.test",
            "role": "user", "permissions": {"chat": STATE["permissions"]}}


def chat():
    question = {"id": "question", "role": "user", "content": "Show the invented text sample.",
                "parentId": None, "childrenIds": ["answer"], "models": ["fixture"], "timestamp": 1700000000}
    answer = {"id": "answer", "role": "assistant", "content": '<details type="reasoning">Synthetic hidden reasoning.</details>\n\n' + STATE["text"],
              "parentId": "question", "childrenIds": [], "model": "fixture", "done": True,
              "timestamp": 1700000002, "usage": {"prompt_tokens": 12, "completion_tokens": 34},
              "sources": [{"id": "source", "url": "https://example.test/source", "title": "Invented source"}]}
    messages = {"question": question, "answer": answer}
    if STATE["versions"]:
        question["childrenIds"].insert(0, "previous")
        messages["previous"] = {**answer, "id": "previous", "content": "Previous synthetic response.", "timestamp": 1700000001}
    return {"id": CHAT_ID, "title": "Message action test", "user_id": user()["id"],
            "created_at": 1700000000, "updated_at": 1700000002, "pinned": False, "archived": False,
            "chat": {"id": CHAT_ID, "title": "Message action test", "models": ["fixture"], "params": {},
                     "history": {"messages": messages, "currentId": "answer"}, "messages": [question, answer]}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path.rstrip("/")
        if path == "/fixture": return self.send(STATE)
        if path in ("", "/health"): return self.send({"status": True})
        if path == "/api/config":
            return self.send({"status": True, "version": "0.0.0-fixture", "name": "Test Server",
                              "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                           "enable_websocket": False, "enable_message_rating": STATE["rating_enabled"]},
                              "default_models": ["fixture"]})
        if path == "/api/version": return self.send({"version": "0.0.0-fixture"})
        if path == "/api/v1/auths": return self.send(user())
        if path == "/api/models": return self.send({"data": [{"id": "fixture", "name": "Test Model", "owned_by": "openai"}]})
        if path == "/api/v1/chats":
            return self.send([{k: v for k, v in chat().items() if k != "chat"}] if parse_qs(parsed.query).get("page", ["1"])[0] == "1" else [])
        if path == "/api/v1/chats/" + CHAT_ID: return self.send(chat())
        if path == "/api/v1/users/user/settings": return self.send({"ui": {}})
        if path == "/api/v1/users/user/permissions": return self.send({"chat": STATE["permissions"]})
        if path.startswith(("/ws/", "/socket.io")): return self.send({}, 404)
        return self.send([])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/fixture":
            STATE.update({k: v for k, v in body.items() if k in STATE and k != "writes"})
            STATE["writes"] = []
            return self.send(STATE)
        STATE["writes"].append({"path": path, "body": body})
        if path == "/api/v1/auths/signin": return self.send({**user(), "token": "synthetic-token", "token_type": "Bearer"})
        if path.endswith("/read"): return self.send(True)
        return self.send({}, 405)

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST


if __name__ == "__main__":
    print("Synthetic fixture: http://127.0.0.1:18083; openui://chat/" + CHAT_ID, flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18083), Handler).serve_forever()
