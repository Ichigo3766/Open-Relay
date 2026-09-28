"""Loopback-only server; returns invented text for synthetic dictation uploads."""
import asyncio
from aiohttp import web
import socketio

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai"}
TRANSCRIPT = " ".join(
    f"Step {step}: Arrange paper stars on the table, then label each one with a different color."
    for step in range(1, 25)
) + " FINAL SENTENCE: The display is ready. 🌟"
CHAT = {"id": "synthetic-caret", "title": "Dictation demo", "user_id": USER["id"],
        "created_at": 1700000000, "updated_at": 1700000000, "archived": False, "pinned": False,
        "chat": {"title": "Dictation demo", "models": [MODEL["id"]], "files": [],
                 "history": {"currentId": None, "messages": {}}, "messages": []}}

app = web.Application()
sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
sio.attach(app, socketio_path="ws/socket.io")

@sio.on("user-join")
async def join(sid, data):
    return {"id": USER["id"]}

async def handle(request):
    path = request.path.rstrip("/")
    result = []
    if path in ("", "/health"):
        result = {"status": True}
    elif path == "/api/config":
        result = {"status": True, "version": "0.0.0-fixture", "name": "Dictation Demo",
                  "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                               "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version":
        result = {"version": "0.0.0-fixture"}
    elif path == "/api/v1/auths/signin":
        result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path == "/api/v1/auths":
        result = USER
    elif path == "/api/models":
        result = {"data": [MODEL]}
    elif path.startswith("/api/v1/models/model"):
        result = MODEL
    elif path == "/api/v1/users/user/settings":
        result = {"ui": {}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"):
        result = [{key: value for key, value in CHAT.items() if key != "chat"}] if request.query.get("page", "1") == "1" else []
    elif path == "/api/v1/chats/synthetic-caret":
        result = CHAT
    elif path == "/api/v1/audio/transcriptions":
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        await request.read()  # Synthetic silence only; never persisted or logged.
        await asyncio.sleep(1)
        result = {"text": TRANSCRIPT}
    return web.json_response(result)

app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
