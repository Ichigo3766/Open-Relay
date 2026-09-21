"""In-memory Open WebUI-shaped fixture; all text, accounts and audio are invented.
Run with a directory for generated speech: python3 mock_server.py /tmp/relay-audio.
Only listens on loopback; never contacts or imports Open WebUI.
"""
import json
from pathlib import Path
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TEXT = "A blue lantern glows beside the paper kite. A green door opens slowly.\n\nThe small garden has three yellow flowers."
CHAT_ID = "02d642ed-d5ee-4270-b8f1-e4f271987f90"
USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MESSAGES = {
    "question": {"id": "question", "role": "user", "content": "Describe the imaginary garden.", "parentId": None, "childrenIds": ["answer"], "models": ["fixture"], "timestamp": 1700000000},
    "answer": {"id": "answer", "role": "assistant", "content": "<think>Invented hidden reasoning must never be spoken.</think>" + TEXT, "parentId": "question", "childrenIds": [], "model": "fixture", "done": True, "timestamp": 1700000001},
}
CHAT = {"id": CHAT_ID, "title": "Imaginary garden", "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "pinned": False, "archived": False,
        "chat": {"id": CHAT_ID, "title": "Imaginary garden", "models": ["fixture"], "params": {}, "history": {"messages": MESSAGES, "currentId": "answer"}, "messages": list(MESSAGES.values())}}
STATE = {"role": "admin", "split": "paragraphs", "voice": "fixture-voice", "requests": [], "updates": [], "delay": 0, "failures": 0}
AUDIO = b""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, value, status=200, content_type="application/json"):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        parsed = urlsplit(self.path); path = parsed.path.rstrip("/")
        if path == "/fixture": return self.send(STATE)
        if path in ("", "/health"): return self.send({"status": True})
        if path == "/api/config":
            return self.send({"status": True, "version": "0.0.0-fixture", "name": "Open WebUI", "features": {"auth": True, "enable_login_form": True, "enable_signup": False, "enable_websocket": False}, "default_models": ["fixture"], "audio": {"tts": {"engine": "openai", "voice": STATE["voice"], "split_on": STATE["split"]}}})
        if path == "/api/version": return self.send({"version": "0.0.0-fixture"})
        if path == "/api/v1/auths": return self.send({**USER, "role": STATE["role"]})
        if path == "/api/models": return self.send({"data": [{"id": "fixture", "name": "Fixture Model", "owned_by": "openai"}]})
        if path == "/api/v1/chats":
            return self.send([{k: v for k, v in CHAT.items() if k != "chat"}] if parse_qs(parsed.query).get("page", ["1"])[0] == "1" else [])
        if path == "/api/v1/chats/" + CHAT_ID: return self.send(CHAT)
        if path == "/api/v1/users/user/settings": return self.send({"ui": {}})
        if path == "/api/v1/users/user/permissions": return self.send({"chat": {"file_upload": True}})
        if path == "/api/v1/audio/voices": return self.send({"voices": [{"id": "fixture-voice", "name": "Fixture Voice"}]})
        if path == "/api/v1/audio/models": return self.send({"models": [{"id": "fixture-tts", "name": "Fixture TTS"}]})
        if path == "/api/v1/audio/config" and STATE["role"] != "admin": return self.send({}, 403)
        if path == "/api/v1/audio/config": return self.send({"tts": {"ENGINE": "openai", "MODEL": "fixture-tts", "VOICE": STATE["voice"], "SPLIT_ON": STATE["split"], "OPENAI_API_BASE_URL": "https://example.test/v1", "OPENAI_PARAMS": {"fixture": True}}, "stt": {"ENGINE": "fixture-stt"}})
        if path.startswith("/ws/") or path.startswith("/socket.io"): return self.send({}, 404)
        return self.send([])
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/fixture":
            for key in ("role", "split", "voice", "delay", "failures"):
                if key in body: STATE[key] = body[key]
            STATE["requests"] = []; STATE["updates"] = []
            return self.send(STATE)
        if path == "/api/v1/auths/signin": return self.send({**USER, "role": STATE["role"], "token": "synthetic-token", "token_type": "Bearer"})
        if path == "/api/v1/audio/speech":
            STATE["requests"].append(body)
            time.sleep(STATE["delay"])
            if STATE["failures"] > 0:
                STATE["failures"] -= 1
                return self.send({"detail": "Invented provider failure"}, 503)
            return self.send(AUDIO, content_type="audio/wav")
        if path == "/api/v1/audio/config/update":
            if STATE["role"] != "admin": return self.send({}, 403)
            STATE["updates"].append(body)
            STATE["split"] = body["tts"]["SPLIT_ON"]
            STATE["voice"] = body["tts"]["VOICE"]
            return self.send(body)
        if path.endswith("/read"): return self.send(True)
        return self.send({}, 405)

if __name__ == "__main__":
    folder = Path(sys.argv[1]); folder.mkdir(parents=True, exist_ok=True)
    wav = folder / "invented-speech.wav"
    subprocess.run(["/usr/bin/say", "-r", "100", "-o", str(wav), "--data-format=LEI16@24000", TEXT + " Every sound in this recording was created for a software test. The paper kite drifts past the garden and then returns to the blue lantern."], check=True)
    AUDIO = wav.read_bytes()
    print("Fixture ready: http://127.0.0.1:18081, openui://chat/" + CHAT_ID, flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
