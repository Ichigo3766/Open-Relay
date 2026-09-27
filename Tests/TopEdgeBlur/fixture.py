"""Loopback-only visual fixture. All text and account values are invented."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai"}
PARAGRAPH = "A coral paper sailboat sits beside a blue ceramic moon. The tiny gallery has a yellow lantern, a silver kite, and a green wooden bird. Every object belongs to this imaginary display."


def chat(identifier, title, question, answer):
    user = {"id": "question", "parentId": None, "childrenIds": ["answer"], "role": "user",
            "content": question, "timestamp": 1700000000}
    reply = {"id": "answer", "parentId": "question", "childrenIds": [], "role": "assistant",
             "model": MODEL["id"], "content": answer, "done": True, "timestamp": 1700000001}
    return {"id": identifier, "title": title, "user_id": USER["id"], "created_at": 1700000000,
            "updated_at": 1700000000, "archived": False, "pinned": False,
            "chat": {"id": identifier, "title": title, "models": [MODEL["id"]],
                     "history": {"currentId": "answer", "messages": {"question": user, "answer": reply}},
                     "messages": [user, reply]}}


CHATS = {
    "top-calibration": chat("top-calibration", "Color calibration",
                            "Color calibration" + "\n" * 60 + "End calibration",
                            "End of the synthetic color sample."),
    "top-prose": chat("top-prose", "Paper gallery", "Describe an imaginary paper gallery.",
                      "\n\n".join(f"## Display {i}\n\n{PARAGRAPH}" for i in range(1, 31))),
    "top-color": chat("top-color", "Color sample", "Please arrange the paper shapes. " + PARAGRAPH * 4,
                      "\n\n".join(f"## Arrangement {i}\n\n{PARAGRAPH}" for i in range(1, 5))),
}


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
            result = {"status": True, "version": "0.0.0-fixture", "name": "Synthetic Gallery",
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False}, "default_models": [MODEL["id"]]}
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
            result = [{k: v for k, v in entry.items() if k != "chat"} for entry in CHATS.values()] if parse_qs(route.query).get("page", ["1"])[0] == "1" else []
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
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
