"""Synthetic note-save failures. Loopback only; never forwards any traffic."""
import asyncio
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "note-chat-demo", "name": "Notes Draft Demo", "owned_by": "openai"}
ORIGINAL = "Fold a square sheet. Add a paper handle."
CONTENT = ORIGINAL
FAIL = True
REQUESTS = []
UPDATE_GATE = asyncio.Event()
UPDATE_GATE.set()

def note():
    return {"id": "draft-paper", "title": "Paper Shapes", "user_id": USER["id"], "write_access": True,
            "created_at": int(time.time() * 1e9), "updated_at": int(time.time() * 1e9),
            "data": {"content": {"md": CONTENT, "html": "<p>Fold a square sheet.</p>", "json": None}}}

@sio.on("user-join")
async def join(sid, data): return {"status": True}

async def handle(request):
    global CONTENT, FAIL
    path = request.path.rstrip("/")
    result = []
    if path == "/_test/reset": CONTENT = ORIGINAL; FAIL = True; REQUESTS.clear(); UPDATE_GATE.set(); result = {}
    elif path == "/_test/hold-update": UPDATE_GATE.clear(); result = {}
    elif path == "/_test/release-update": UPDATE_GATE.set(); result = {}
    elif path == "/_test/succeed": FAIL = False; result = {}
    elif path == "/_test/conflict": CONTENT = "Use a paper strip instead."; FAIL = False; result = {}
    elif path == "/_test/state": result = {"requests": REQUESTS, "content": CONTENT}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-draft-fixture", "features": {
        "auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False, "enable_notes": True}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-draft-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path.startswith("/api/v1/notes"):
        if request.headers.get("Authorization") != "Bearer synthetic-token": raise web.HTTPUnauthorized()
        REQUESTS.append({"method": request.method, "path": path})
        if path in ("/api/v1/notes", "/api/v1/notes/search"): result = [note()]
        elif path == "/api/v1/notes/draft-paper": result = note()
        elif path == "/api/v1/notes/draft-paper/update":
            await UPDATE_GATE.wait()
            if FAIL: return web.json_response({"detail": "Synthetic save failure"}, status=503)
            body = await request.json()
            if "data" in body: CONTENT = body["data"]["content"]["md"]
            result = note()
        else: raise web.HTTPNotFound()
    elif path.startswith("/api/tasks"): result = {"tasks": []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
