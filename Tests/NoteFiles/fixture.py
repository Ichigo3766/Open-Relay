"""Fresh synthetic note/file server; binds loopback and never forwards requests."""
import io
import json
import time
import wave
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "notes-demo", "name": "Notes Attachments Demo", "owned_by": "openai"}
GUIDE = b"PAPER LANTERNS\n\n1. Start with a square sheet.\n2. Fold the edges inward.\n3. Add a paper handle.\n\nSynthetic attachment preview.\n"
buffer = io.BytesIO()
with wave.open(buffer, "wb") as audio:
    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
    audio.writeframes(b"\x00\x00" * 8000 * 10)
AUDIO = buffer.getvalue()
ORIGINALS = {"guide": (GUIDE, "text/plain"), "audio": (AUDIO, "audio/wav")}
INITIAL_FILES = [{"id": "guide", "type": "file", "name": "lantern-guide.txt", "size": len(GUIDE),
                  "url": "guide", "file": {"meta": {"content_type": "text/plain"}},
                  "future_metadata": {"nested": [1, True, None]}},
                 {"id": "audio", "type": "file", "name": "quiet-sample.wav", "size": len(AUDIO),
                  "file": {"meta": {"content_type": "audio/wav"}}}]
FILES = list(INITIAL_FILES)
UPDATES = []; CONTENT = []; UPLOADS = []; FAIL = False; SLOW = False; READER = False; OPEN_FAIL = False

def note():
    return {"id": "paper", "title": "Paper Lanterns", "user_id": USER["id"], "write_access": not READER,
            "access_grants": [], "created_at": 1780000000000000000, "updated_at": 1780000000000000000,
            "data": {"content": {"md": "# Folding checklist\n\nUse a square sheet. Fold the edges inward.\n\nThe attached guide and quiet audio sample are synthetic.",
                                 "html": "<p>Keep rich formatting</p>", "json": {"type": "doc", "content": []}},
                     "versions": [{"revision": 1}], "files": FILES}}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, data, content_type="application/json", status=200):
        self.send_response(status); self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def reply(self, obj, status=200): self.send(json.dumps(obj).encode(), status=status)
    def do_GET(self):
        global OPEN_FAIL
        path = urlsplit(self.path).path.rstrip("/"); result = []
        if path == "/_test/state": result = {"updates": UPDATES, "files": FILES, "content": CONTENT, "uploads": UPLOADS}
        elif path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-note-files-fixture", "name": MODEL["name"],
                      "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                                   "enable_websocket": False, "enable_channels": False, "enable_notes": True},
                      "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-note-files-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/notes": result = [note()]
        elif path == "/api/v1/notes/paper": result = note()
        elif path.startswith("/api/v1/files/"):
            if self.headers.get("Authorization") != "Bearer synthetic-token": return self.reply({}, 401)
            file_id = path.split("/")[4]
            if file_id not in ORIGINALS: return self.reply({}, 404)
            if path.endswith("/content"):
                CONTENT.append({"id": file_id, "authorized": True})
                if SLOW: time.sleep(4)
                if OPEN_FAIL:
                    OPEN_FAIL = False
                    return self.reply({"detail": "Synthetic preview failure"}, 503)
                return self.send(*ORIGINALS[file_id])
            if path.endswith("/process/status"):
                return self.send(b'data: {"status":"completed"}\n\n', "text/event-stream")
            result = {"id": file_id, "meta": {"content_type": ORIGINALS[file_id][1]}}
        elif path.endswith("/profile/image"): return self.reply({}, 404)
        self.reply(result)
    def do_POST(self):
        global FILES, UPDATES, CONTENT, UPLOADS, FAIL, SLOW, READER, OPEN_FAIL
        path = urlsplit(self.path).path.rstrip("/")
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if path == "/api/v1/files":
            if self.headers.get("Authorization") != "Bearer synthetic-token": return self.reply({}, 401)
            message = BytesParser(policy=default).parsebytes(
                ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + raw)
            part = next(p for p in message.iter_parts() if p.get_filename())
            file_id = "upload-" + str(len(UPLOADS) + 1)
            data = part.get_payload(decode=True); name = part.get_filename()
            ORIGINALS[file_id] = (data, part.get_content_type())
            UPLOADS.append({"id": file_id, "name": name, "size": len(data)})
            return self.reply({"id": file_id, "filename": name, "meta": {"content_type": part.get_content_type(), "collection_name": "file-" + file_id}})
        body = json.loads(raw or "{}")
        if path == "/_test/reset":
            FILES = list(INITIAL_FILES); UPDATES = []; CONTENT = []; UPLOADS = []
            FAIL = False; SLOW = False; READER = False; OPEN_FAIL = False
        elif path == "/_test/fail": FAIL = True
        elif path == "/_test/slow": SLOW = True
        elif path == "/_test/reader": READER = True
        elif path == "/_test/open-fail": OPEN_FAIL = True
        elif path == "/api/v1/auths/signin": return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        elif path == "/api/v1/notes/paper/update":
            if self.headers.get("Authorization") != "Bearer synthetic-token": return self.reply({}, 401)
            if READER: return self.reply({}, 403)
            UPDATES.append(body)
            if set(body) != {"data"} or set(body["data"]) != {"files"}: return self.reply({"detail": "Files-only update required"}, 400)
            if FAIL:
                FAIL = False
                return self.reply({"detail": "Synthetic attachment save failed"}, 503)
            FILES = body["data"]["files"]
            return self.reply(note())
        self.reply({})

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
