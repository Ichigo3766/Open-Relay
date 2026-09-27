"""Loopback-only sidebar layout fixture. All content and credentials are invented."""
from aiohttp import web
from pathlib import Path
import socketio

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai"}
MESSAGES = {
    "question": {"id": "question", "role": "user", "content": "Show a sample layout.",
                 "parentId": None, "childrenIds": ["answer"], "timestamp": 1700000000},
    "answer": {"id": "answer", "role": "assistant", "content": "This conversation contains only invented content for a sidebar layout test.",
               "parentId": "question", "childrenIds": [], "model": MODEL["id"], "done": True, "timestamp": 1700000001},
}
CHAT = {"id": "synthetic-sidebar", "title": "Sidebar layout sample", "user_id": USER["id"],
        "created_at": 1700000000, "updated_at": 1700000001, "archived": False, "pinned": False,
        "chat": {"title": "Sidebar layout sample", "models": [MODEL["id"]], "files": [],
                 "history": {"currentId": "answer", "messages": MESSAGES}, "messages": list(MESSAGES.values())}}

app = web.Application()
sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
sio.attach(app, socketio_path="ws/socket.io")


@sio.on("user-join")
async def join(sid, data):
    return {"id": USER["id"]}


async def handle(request):
    path = request.path.rstrip("/")
    if path == "/favicon.ico":
        return web.FileResponse(Path(__file__).resolve().parents[2] / "Open UI/Assets.xcassets/AppIconImage.imageset/OR.png")
    result = []
    if path in ("", "/health"):
        result = {"status": True}
    elif path == "/api/config":
        result = {"status": True, "version": "0.0.0-fixture", "name": "Layout Demo",
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
    elif path == "/api/v1/chats/synthetic-sidebar":
        result = CHAT
    return web.json_response(result)


app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
