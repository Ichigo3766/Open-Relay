"""Loopback-only synthetic model editor fixture. No real instance is used."""
import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
ORIGINAL = {
    "id": "geometry", "name": "Geometry Guide", "user_id": "demo-user", "is_active": True,
    "write_access": True, "access_grants": [], "base_model_id": "demo-base",
    "meta": {"description": "A synthetic model for editor checks.", "actionIds": ["demo-action"],
             "skillIds": ["demo-skill"], "terminalId": "demo-terminal",
             "chat_variables_schema": {"fields": [{"key": "topic", "type": "text", "required": True}]},
             "capabilities": {"vision": True, "future_capability": False}},
    "params": {"custom_number": 4096, "custom_flag": True, "custom_object": {"type": "json_object"}},
}
MODEL = copy.deepcopy(ORIGINAL)
SAVES = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        route = urlsplit(self.path)
        path, args = route.path.rstrip("/"), parse_qs(route.query)
        if path == "/_test/state":
            return self.reply({"model": MODEL, "saves": SAVES})
        if path in ("", "/health"):
            return self.reply({"status": True})
        if path == "/api/config":
            return self.reply({"status": True, "version": "0.0.0-model-fixture", "name": "Model Workshop",
                               "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                            "enable_websocket": False, "enable_channels": False},
                               "default_models": ["geometry"]})
        if path == "/api/version":
            return self.reply({"version": "0.0.0-model-fixture"})
        if path == "/api/v1/auths":
            return self.reply(USER)
        if path in ("/api/models", "/api/models/base"):
            return self.reply({"data": [{"id": "geometry", "name": MODEL["name"], "owned_by": "openai", "info": MODEL}]})
        if path == "/api/v1/models/list":
            return self.reply({"items": [MODEL] if args.get("page", ["1"])[0] == "1" else [], "total": 1})
        if path == "/api/v1/models/model":
            return self.reply(MODEL)
        if path == "/api/v1/models":
            return self.reply([MODEL])
        if path == "/api/v1/users/user/settings":
            return self.reply({"ui": {"models": ["geometry"], "pinnedModels": []}})
        if path == "/api/v1/functions":
            return self.reply([{"id": "demo-action", "name": "Copy Summary", "type": "action", "is_active": True, "is_global": False}])
        if path == "/api/v1/skills/list":
            return self.reply({"items": [{"id": "demo-skill", "name": "Outline Steps", "description": "Synthetic skill"}], "total": 1})
        if path.startswith("/static/"):
            return self.reply({"detail": "Not found"}, 404)
        return self.reply([])

    def do_POST(self):
        global MODEL
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/_test/reset":
            MODEL = copy.deepcopy(ORIGINAL)
            SAVES.clear()
            return self.reply({"ok": True})
        if path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        if path == "/api/v1/models/model/update":
            if self.headers.get("Authorization") != "Bearer synthetic-token":
                return self.reply({"detail": "Unauthorized"}, 401)
            SAVES.append(body)
            MODEL.update(body)
            return self.reply(MODEL)
        if path == "/api/v1/models/model/access/update":
            return self.reply(MODEL)
        return self.reply({})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
