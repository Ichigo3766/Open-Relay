"""Synthetic, loopback-only note sharing fixture. Never connects to a real server."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

PERMISSIONS = {"sharing": {"notes": True, "public_notes": True},
               "access_grants": {"allow_users": True, "allow_groups": True}}
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user", "permissions": PERMISSIONS}
MODEL = {"id": "notes-demo", "name": "Notes Sharing Demo", "owned_by": "openai"}
GRANTS = []
UPDATES = []
SEARCHES = []
FAIL = False
MODE = "owner"


def note():
    return {"id": "paper", "title": "Paper Lanterns", "user_id": "other" if MODE == "reader" else USER["id"],
            "write_access": MODE != "reader", "access_grants": GRANTS,
            "data": {"content": {"md": "# Folding checklist\n\nUse a square sheet. Fold the edges inward.\n\nShare this imaginary craft plan with a teammate."},
                     "files": [{"id": "untouched-file", "type": "file"}]},
            "created_at": 1780000000000000000, "updated_at": 1780000000000000000}


def person(index):
    return {"id": f"person-{index}", "name": f"Demo Reader {index}", "email": f"reader{index}@example.test", "role": "user"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

    def do_GET(self):
        url = urlsplit(self.path); path = url.path.rstrip("/"); query = parse_qs(url.query)
        result = []
        if path == "/_test/state": result = {"updates": UPDATES, "grants": GRANTS, "searches": SEARCHES}
        elif path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-notes-fixture", "name": MODEL["name"],
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": False, "enable_notes": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-notes-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/notes": result = [note()]
        elif path == "/api/v1/notes/paper": result = note()
        elif path == "/api/v1/users/search":
            page = int(query.get("page", ["1"])[0]); text = query.get("query", [""])[0]
            SEARCHES.append({"query": text, "page": page})
            people = [person(i) for i in range(1, 5) if not text or text.lower() in f"Demo Reader {i}".lower()]
            result = {"users": people[(page-1)*2:page*2], "total": len(people)}
        elif path.startswith("/api/v1/users/person-") and path.endswith("/info"):
            result = person(int(path.split("/")[-2].split("-")[-1]))
        elif path == "/api/v1/groups":
            result = [{"id": "paper-team", "name": "Paper Team", "description": "Imaginary collaborators", "member_count": 3,
                       "user_id": USER["id"], "created_at": 1780000000, "updated_at": 1780000000}]
        elif path.endswith("/profile/image"): return self.reply({}, 404)
        self.reply(result)

    def do_POST(self):
        global GRANTS, UPDATES, SEARCHES, FAIL, MODE
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/_test/reset": GRANTS = []; UPDATES = []; SEARCHES = []; FAIL = False; MODE = "owner"
        elif path == "/_test/fail": FAIL = True
        elif path == "/_test/reader": MODE = "reader"
        elif path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        elif path == "/api/v1/notes/paper/access/update":
            if self.headers.get("Authorization") != "Bearer synthetic-token": return self.reply({}, 401)
            if MODE == "reader": return self.reply({}, 403)
            UPDATES.append(body)
            if set(body) != {"access_grants"}: return self.reply({"detail": "Only grants may change"}, 400)
            for grant in body["access_grants"]:
                if grant["permission"] == "write" and {**grant, "permission": "read"} not in body["access_grants"]:
                    return self.reply({"detail": "Native read and write checks are independent"}, 400)
            time.sleep(0.4)
            if FAIL:
                FAIL = False
                return self.reply({"detail": "Synthetic access failure"}, 503)
            GRANTS = body["access_grants"]
            return self.reply(note())
        elif path == "/api/v1/notes/paper/update":
            return self.reply({"detail": "Sharing must not change note content"}, 400)
        self.reply({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
