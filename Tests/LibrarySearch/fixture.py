"""Loopback-only search fixture. Every account, chat, folder and file is invented."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai"}
FOLDER = {"id": "paper-workshop", "name": "Lantern workshop", "parent_id": None,
          "is_expanded": False, "created_at": 1700000000, "updated_at": 1700000000,
          "data": {}, "meta": {}}
KNOWLEDGE = {"id": "paper-crafts", "name": "Paper crafts", "description": "Plans for paper lantern displays.",
             "created_at": 1700000000, "updated_at": 1700000000, "user_id": USER["id"]}
FILE = {"id": "assembly-guide", "filename": "Assembly guide.txt", "meta": {"name": "Assembly guide.txt"},
        "collection": KNOWLEDGE, "created_at": 1700000000, "updated_at": 1700000000}
CONTENT = ("Fold a square sheet along its diagonal. Unfold it and press the crease flat.\n" * 60
           + "Hang the yellow lantern above the miniature harbor. Leave room for the paper boats.\n"
           + "The display is imaginary and all materials are made from paper.")


def chat(identifier, title, answer):
    user = {"id": "question", "parentId": None, "childrenIds": ["answer"], "role": "user",
            "content": "Describe an imaginary paper display.", "timestamp": 1700000000}
    reply = {"id": "answer", "parentId": "question", "childrenIds": [], "role": "assistant",
             "model": MODEL["id"], "content": answer, "done": True, "timestamp": 1700000001}
    return {"id": identifier, "title": title, "user_id": USER["id"], "created_at": 1700000000,
            "updated_at": 1700000000, "archived": False, "pinned": False,
            "chat": {"id": identifier, "title": title, "models": [MODEL["id"]],
                     "history": {"currentId": "answer", "messages": {"question": user, "answer": reply}},
                     "messages": [user, reply]}}


CHATS = {
    "paper-gallery": chat("paper-gallery", "Paper gallery", "A yellow lantern lights the miniature harbor beside a silver kite."),
    "garden-notes": chat("garden-notes", "Garden notes", "Blue paper flowers surround a tiny wooden bench."),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        route = urlsplit(self.path)
        path = route.path.rstrip("/")
        args = parse_qs(route.query)
        query = args.get("query", args.get("text", [""]))[0].lower()
        page = int(args.get("page", ["1"])[0])
        result = []
        status = 200
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
        elif path == "/api/v1/chats/search":
            if query == "slow":
                time.sleep(2)
            if query == "pages":
                result = [{"id": f"page-{i}", "title": f"Paper display {i:02}", "snippet": "Pages of paper designs."}
                          for i in range((page - 1) * 60, min(page * 60, 61))]
            else:
                result = [{"id": entry["id"], "title": entry["title"], "snippet": entry["chat"]["messages"][1]["content"]}
                          for entry in CHATS.values()
                          if query in json.dumps(entry).lower() or query == "offline"] if page == 1 else []
        elif path in ("/api/v1/chats", "/api/v1/chats/list"):
            result = [{k: v for k, v in entry.items() if k != "chat"} for entry in CHATS.values()] if page == 1 else []
        elif path.startswith("/api/v1/chats/"):
            result = CHATS.get(path.split("/")[4], [])
        elif path == "/api/v1/folders":
            result = [FOLDER]
        elif path == "/api/v1/folders/paper-workshop":
            result = FOLDER
        elif path == "/api/v1/knowledge/search":
            rows = [KNOWLEDGE] if query in (KNOWLEDGE["name"] + KNOWLEDGE["description"]).lower() else []
            result = {"items": rows if page == 1 else [], "total": len(rows)}
        elif path == "/api/v1/knowledge/search/files":
            if query == "offline":
                status, result = 503, {"detail": "Synthetic unavailable response"}
            else:
                searchable = FILE["filename"] + (CONTENT if args.get("include_content") == ["true"] else "")
                rows = [FILE] if query in searchable.lower() else []
                result = {"items": rows if page == 1 else [], "total": len(rows)}
        elif path == "/api/v1/knowledge/paper-crafts/files":
            result = {"items": [FILE] if page == 1 else [], "total": 1}
        elif path == "/api/v1/knowledge/paper-crafts":
            result = KNOWLEDGE
        elif path == "/api/v1/files/assembly-guide/data/content":
            result = {"content": CONTENT}
        elif path == "/api/v1/files/assembly-guide":
            result = {**FILE, "data": {"content": CONTENT}}
        data = json.dumps(result).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.do_GET()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
