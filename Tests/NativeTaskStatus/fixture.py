"""Synthetic task snapshots over real Socket.IO; no Open WebUI imports or instance data."""
import copy
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "consent-demo", "name": "Tool Consent Demo", "owned_by": "openai"}
INITIAL = [{"id": "paper", "content": "Fold paper", "status": "pending"}, {"id": "sky", "content": "Color the paper sky", "status": "pending"}]
CHAT = {}
CHAT_ID = "synthetic-tasks"
WRITES = []
ACTIVE = None

def reset():
    global ACTIVE
    now = int(time.time())
    CHAT.clear(); WRITES.clear(); ACTIVE = None
    CHAT.update(id="synthetic-tasks", title="Synthetic task list", tasks=copy.deepcopy(INITIAL), models=[MODEL["id"]], history={"currentId": "assistant", "messages": {
        "user": {"id": "user", "role": "user", "content": "Plan a paper craft.", "parentId": None, "childrenIds": ["assistant"], "timestamp": now},
        "assistant": {"id": "assistant", "role": "assistant", "model": MODEL["id"], "content": "Two small craft tasks are ready.", "parentId": "user", "childrenIds": [], "done": True, "timestamp": now}
    }})

def envelope():
    return {"id": CHAT_ID, "title": CHAT["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "tasks": CHAT["tasks"], "chat": CHAT}

async def tasks(updated):
    CHAT["tasks"] = updated
    await sio.emit("events", {"chat_id": CHAT_ID, "message_id": CHAT["history"]["currentId"], "data": {"type": "chat:message:tasks", "data": {"tasks": updated}}})

@sio.on("user-join")
async def join(sid, data):
    return {"status": True}

async def handle(request):
    global ACTIVE
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/state": result = {"tasks": CHAT["tasks"], "writes": WRITES}
    elif path == "/_test/tasks": await tasks(body["tasks"]); result = {"ok": True}
    elif path == "/_test/finish":
        if ACTIVE:
            await sio.emit("events", {"chat_id": CHAT_ID, "message_id": ACTIVE["id"], "session_id": ACTIVE["session_id"], "data": {"type": "chat:completion", "data": {"content": "Synthetic work finished.", "done": True}}})
            ACTIVE = None
        result = {"ok": True}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-task-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-task-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k != "chat"}]
    elif path == "/api/v1/chats/synthetic-tasks":
        if "chat" in body: CHAT.update(body["chat"])
        result = envelope()
    elif path == "/api/chat/completions":
        ACTIVE = body
        await tasks([{**INITIAL[0], "status": "in_progress"}, INITIAL[1]])
        result = {"task_id": "synthetic-task"}
    elif path.endswith("/update") and path.startswith("/api/v1/tasks/"):
        WRITES.append(body)
        return web.json_response({"detail": "Not Found"}, status=404)
    elif path.startswith("/api/tasks"): result = {"tasks": ["synthetic-task"] if ACTIVE else []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
