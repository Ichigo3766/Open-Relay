"""Synthetic live/saved HTML embeds, using real Socket.IO on loopback only."""
import copy
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "embed-demo", "name": "Embed Demo", "owned_by": "openai"}
CHAT_ID = "synthetic-embeds"
CHAT = {}
ACTIVE = None
TARGET = "answer"
EVENTS = []

def html(title):
    return '<html><body style="margin:0;padding:24px;background:#e8f4fa;color:#17324a;font:18px -apple-system"><h2>' + title + '</h2><p>A freshly invented craft preview.</p></body></html>'

def reset():
    global ACTIVE, TARGET
    ACTIVE = None; TARGET = "answer"; EVENTS.clear(); CHAT.clear()
    now = int(time.time())
    CHAT.update(id=CHAT_ID, title="Synthetic embed preview", models=[MODEL["id"]], history={"currentId": "answer", "messages": {
        "question": {"id": "question", "role": "user", "content": "Show a paper craft preview.", "parentId": None, "childrenIds": ["answer"], "timestamp": now},
        "answer": {"id": "answer", "role": "assistant", "content": "The preview appears below.", "model": MODEL["id"], "parentId": "question", "childrenIds": [], "timestamp": now, "done": True, "embeds": []}
    }})

def envelope():
    return {"id": CHAT_ID, "title": CHAT["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "chat": CHAT}

async def emit(kind, payload, message_id=None):
    message_id = message_id or TARGET
    EVENTS.append({"type": kind, "message_id": message_id})
    await sio.emit("events", {"chat_id": CHAT_ID, "message_id": message_id, "data": {"type": kind, "data": payload}})

@sio.on("user-join")
async def join(sid, data): return {"status": True}

async def handle(request):
    global ACTIVE, TARGET
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/state": result = {"active": ACTIVE is not None, "events": EVENTS}
    elif path == "/_test/embed":
        target = TARGET
        embeds = [] if body.get("clear") else [html(body.get("title", "Paper star preview"))]
        CHAT["history"]["messages"][target]["embeds"] = embeds
        await emit(body.get("type", "chat:message:embeds"), {"embeds": embeds}, target)
        result = {"ok": True}
    elif path == "/_test/finish":
        if ACTIVE:
            node = CHAT["history"]["messages"][ACTIVE["id"]]
            node.update(content="The live preview is ready.", done=True)
            await emit("chat:completion", {"content": node["content"], "done": True})
            ACTIVE = None
        result = {"ok": True}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-embed-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-embed-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k != "chat"}]
    elif path == "/api/v1/chats/" + CHAT_ID:
        if "chat" in body: CHAT.update(copy.deepcopy(body["chat"]))
        result = envelope()
    elif path == "/api/chat/completions":
        ACTIVE = body
        TARGET = body["id"]
        await emit("chat:completion", {"content": "The live preview is arriving.", "done": False})
        result = {"task_id": "synthetic-task"}
    elif path.startswith("/api/tasks"): result = {"tasks": ["synthetic-task"] if ACTIVE else []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
