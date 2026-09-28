"""Loopback-only, freshly invented library. No production imports or data."""
import fnmatch
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODELS = [{"id": f"demo-{i}", "name": name, "owned_by": "openai"}
          for i, name in enumerate(["Paper Planner", "Kite Designer", "Harbor Guide"])]
CONTENT = b"Paper workshop guide\n\nFold a square sheet into an imaginary boat.\n"


def pdf():
    text = b"BT /F1 24 Tf 50 730 Td (Paper workshop guide) Tj 0 -40 Td /F1 14 Tf (Fold a square sheet into an imaginary boat.) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Length " + str(len(text)).encode() + b" >>\nstream\n" + text + b"\nendstream"]
    data, offsets = b"%PDF-1.4\n", [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    return data + f"trailer << /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()


PDF = pdf()
FILES = [{"id": f"paper-{i}", "filename": "Paper guide.pdf" if i == 0 else f"Paper plan {i:02}.pdf",
          "meta": {"content_type": "application/pdf", "size": len(PDF)}} for i in range(32)]
FILES += [{"id": "notes", "filename": "Paper notes.txt", "meta": {"content_type": "text/plain", "size": len(CONTENT)}}]
REQUESTS, ATTEMPTS = [], {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200, mime="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        route = urlsplit(self.path)
        path, args = route.path.rstrip("/"), parse_qs(route.query)
        if path == "/_test/metrics":
            return self.reply(REQUESTS)
        REQUESTS.append({"path": path, "query": args, "authorized": self.headers.get("Authorization") == "Bearer synthetic-token"})
        if path in ("", "/health"):
            return self.reply({"status": True})
        if path == "/api/config":
            return self.reply({"status": True, "version": "0.0.0-search-fixture", "name": "Paper Workshop",
                               "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                            "enable_websocket": False, "enable_channels": False},
                               "default_models": [MODELS[0]["id"]]})
        if path == "/api/version":
            return self.reply({"version": "0.0.0-search-fixture"})
        if path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        if path == "/api/v1/auths":
            return self.reply(USER)
        if path == "/api/models":
            return self.reply({"data": MODELS})
        if path == "/api/v1/models/model":
            return self.reply(next((m for m in MODELS if m["id"] == args.get("id", [""])[0]), MODELS[0]))
        if path == "/api/v1/users/user/settings":
            return self.reply({"ui": {"models": [MODELS[0]["id"]], "pinnedModels": [m["id"] for m in MODELS]}})
        if path == "/api/v1/files/search":
            if not REQUESTS[-1]["authorized"]:
                return self.reply({"detail": "Unauthorized"}, 401)
            pattern = args.get("filename", [""])[0].lower()
            if "offline" in pattern:
                return self.reply({"detail": "Synthetic temporary failure"}, 503)
            if "slow" in pattern:
                time.sleep(2)
            if "retry" in pattern or "waiting" in pattern:
                return self.reply([{"id": "retry" if "retry" in pattern else "waiting", "filename": "Retry example.pdf" if "retry" in pattern else "Waiting example.pdf"}])
            rows = [f for f in FILES if fnmatch.fnmatch(f["filename"].lower(), pattern)]
            skip, limit = int(args.get("skip", [0])[0]), int(args.get("limit", [30])[0])
            rows = rows[skip:skip + limit]
            return self.reply(rows) if rows else self.reply({"detail": "No files found matching the pattern."}, 404)
        if path.startswith("/api/v1/files/"):
            identifier = path.split("/")[4]
            if path.endswith("/data/content"):
                return self.reply({"content": CONTENT.decode()})
            if path.endswith("/content"):
                if not REQUESTS[-1]["authorized"]:
                    return self.reply({"detail": "Unauthorized"}, 401)
                ATTEMPTS[identifier] = ATTEMPTS.get(identifier, 0) + 1
                if identifier == "retry" and ATTEMPTS[identifier] == 1:
                    return self.reply({"detail": "Synthetic download failure"}, 503)
                if identifier == "waiting":
                    time.sleep(8)
                return self.reply(CONTENT if identifier == "notes" else PDF, mime="text/plain" if identifier == "notes" else "application/pdf")
            return self.reply({**FILES[0], "data": {"content": CONTENT.decode()}})
        if path == "/api/v1/knowledge/search":
            return self.reply({"items": [], "total": 0})
        if path == "/api/v1/knowledge/search/files":
            rows = [{**FILES[0], "collection": {"name": "Paper collection"}}] if args.get("query", [""])[0] in ("paper", "imaginary") else []
            return self.reply({"items": rows, "total": len(rows)})
        if path == "/api/v1/folders":
            return self.reply([{"id": "crafts", "name": "Paper crafts", "parent_id": None, "is_expanded": False, "data": {}, "meta": {}}])
        return self.reply([])

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/_test/reset":
            REQUESTS.clear()
            ATTEMPTS.clear()
            return self.reply({"ok": True})
        self.do_GET()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
