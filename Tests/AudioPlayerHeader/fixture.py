"""Loopback-only synthetic chat and generated tone; no real provider or recordings."""
import io
import json
import math
import struct
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MODEL = {"id": "synthetic-library", "name": "Synthetic Test Model", "owned_by": "fixture"}
USER = {"id": "fixture-user", "name": "Audio Demo", "email": "demo@example.test", "role": "user"}
CHAT_ID = "30000000-0000-4000-8000-000000000020"
MESSAGES = {
    "question": {"id": "question", "role": "user", "content": "Describe invented station observation 1.",
                 "parentId": None, "childrenIds": ["answer"], "models": [MODEL["id"]]},
    "answer": {"id": "answer", "role": "assistant", "content": "A paper rover follows an imaginary orange trail. This invented text tests the audio controls.",
               "parentId": "question", "childrenIds": [], "model": MODEL["id"], "done": True},
}
CHAT = {"id": CHAT_ID, "title": "Audio Header Demo", "user_id": USER["id"],
        "created_at": 1700000000, "updated_at": 1700000000,
        "pinned": False, "archived": False,
        "chat": {"id": CHAT_ID, "title": "Audio Header Demo", "models": [MODEL["id"]],
                 "params": {}, "history": {"messages": MESSAGES, "currentId": "answer"},
                 "messages": list(MESSAGES.values())}}
AUDIO = io.BytesIO()
with wave.open(AUDIO, "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(16000)
    output.writeframes(b"".join(struct.pack("<h", int(180 * math.sin(2 * math.pi * 220 * i / 16000)))
                              for i in range(16000 * 45)))
AUDIO = AUDIO.getvalue()


class Handler(BaseHTTPRequestHandler):
    mode = "success"

    def log_message(self, *_):
        pass

    def send(self, value, status=200, content_type="application/json"):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path.rstrip("/")
        if path in ("", "/health"):
            return self.send({"status": True})
        if path == "/api/config":
            return self.send({"status": True, "version": "0.0.0-audio-fixture",
                              "features": {"auth": True, "enable_login_form": True},
                              "default_models": [MODEL["id"]],
                              "audio": {"tts": {"engine": "openai", "voice": "synthetic", "split_on": "none"}}})
        if path == "/api/version": return self.send({"version": "0.0.0-audio-fixture"})
        if path == "/api/v1/auths": return self.send(USER)
        if path == "/api/models": return self.send({"data": [MODEL]})
        if path == "/api/v1/models/model": return self.send(MODEL)
        if path == "/api/v1/users/user/settings": return self.send({"ui": {"models": [MODEL["id"]]}})
        if path == "/api/v1/users/user/permissions": return self.send({"chat": {"tts": True}})
        if path == "/api/v1/chats":
            return self.send([{k: v for k, v in CHAT.items() if k != "chat"}]
                             if parse_qs(parsed.query).get("page", ["1"])[0] == "1" else [])
        if path == f"/api/v1/chats/{CHAT_ID}": return self.send(CHAT)
        if path.startswith(("/ws/", "/socket.io")): return self.send({}, 404)
        return self.send([])

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/fixture/audio-control":
            mode = json.loads(body)["mode"]
            if mode not in ("success", "failure"): return self.send({}, 400)
            Handler.mode = mode
            return self.send({"synthetic": True, "mode": mode})
        if path == "/api/v1/audio/speech":
            mode = Handler.mode
            time.sleep(4)
            if mode == "failure": return self.send({"detail": "Synthetic preparation failure"}, 503)
            return self.send(AUDIO, content_type="audio/wav")
        if path == "/api/v1/auths/signin":
            return self.send({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        if path == f"/api/v1/chats/{CHAT_ID}": return self.send(CHAT)
        if path.endswith("/read"): return self.send(True)
        return self.send({})


if __name__ == "__main__":
    print("Synthetic audio fixture: http://127.0.0.1:18191", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
