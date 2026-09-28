"""Loopback-only full-app check. Accepts only the three invented paragraphs below."""
import io
import json
import math
import struct
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TEXT = ["An imaginary balloon rises above a paper town.", "Brief sentence.",
        "A tiny cardboard train arrives at the pretend station."]
MODEL = {"id": "prefetch-demo", "name": "Audio Prefetch Demo", "owned_by": "fixture"}
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
CHAT_ID = "prefetch-demo-chat"
MESSAGE = {"id": "answer", "role": "assistant", "content": "\n\n".join(TEXT),
           "parentId": None, "childrenIds": [], "model": MODEL["id"], "done": True}
CHAT = {"id": CHAT_ID, "title": "Audio Prefetch Demo", "user_id": USER["id"],
        "created_at": 1780000000, "updated_at": 1780000000, "pinned": False, "archived": False,
        "chat": {"id": CHAT_ID, "title": "Audio Prefetch Demo", "models": [MODEL["id"]],
                 "params": {}, "history": {"messages": {"answer": MESSAGE}, "currentId": "answer"},
                 "messages": [MESSAGE]}}
LOCK = threading.Lock()
REQUESTS = []


def tone(seconds):
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
        audio.writeframes(b"".join(struct.pack("<h", int(100 * math.sin(i * math.tau * 220 / 16000)))
                                 for i in range(int(16000 * seconds))))
    return output.getvalue()


AUDIO = [tone(8), tone(0.15), tone(3)]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value, status=200, content_type="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        url = urlsplit(self.path); path = url.path.rstrip("/")
        result = []
        if path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-prefetch-fixture",
                      "features": {"auth": True, "enable_login_form": True, "enable_websocket": False},
                      "default_models": [MODEL["id"]],
                      "audio": {"tts": {"engine": "openai", "voice": "synthetic", "split_on": "paragraphs"}}}
        elif path == "/api/version": result = {"version": "0.0.0-prefetch-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
        elif path == "/api/v1/models/model": result = MODEL
        elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
        elif path == "/api/v1/users/user/permissions": result = {"chat": {"tts": True}}
        elif path == "/api/v1/chats":
            result = [{k: v for k, v in CHAT.items() if k != "chat"}] if parse_qs(url.query).get("page", ["1"])[0] == "1" else []
        elif path == "/api/v1/chats/" + CHAT_ID: result = CHAT
        elif path == "/fixture/requests":
            with LOCK: result = [dict(item) for item in REQUESTS]
        self.reply(result)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/api/v1/auths/signin":
            return self.reply({**USER, "token": "synthetic-token", "token_type": "Bearer"})
        if path == "/fixture/reset":
            with LOCK: REQUESTS.clear()
            return self.reply({"synthetic": True})
        if path == "/api/v1/audio/speech":
            if self.headers.get("Authorization") != "Bearer synthetic-token": return self.reply({}, 401)
            if body.get("input") not in TEXT: return self.reply({}, 400)
            index = TEXT.index(body["input"])
            request = {"index": index, "started": time.monotonic(), "authenticated": True}
            with LOCK: REQUESTS.append(request)
            time.sleep(0.6)
            with LOCK: request["finished"] = time.monotonic()
            return self.reply(AUDIO[index], content_type="audio/wav")
        self.reply(CHAT if path == "/api/v1/chats/" + CHAT_ID else {})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18191), Handler).serve_forever()
