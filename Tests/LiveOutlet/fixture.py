"""Fresh synthetic outlet text, saved history and real Socket.IO; loopback only."""
import asyncio
import copy
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "outlet-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "outlet-demo", "name": "Craft Demo", "owned_by": "openai"}
CHAT_ID = "synthetic-outlet"
CHAT = {}
ACTIVE = None
TARGET = "answer"

def output(text):
    return [{"type": "message", "content": [{"type": "output_text", "text": text}]}]

def reset():
    global ACTIVE, TARGET
    ACTIVE = None; TARGET = "answer"; CHAT.clear()
    now = int(time.time())
    CHAT.update(id=CHAT_ID, title="Synthetic paper colors", models=[MODEL["id"]], history={"currentId": "answer", "messages": {
        "question": {"id": "question", "role": "user", "content": "Choose a paper color for a craft.", "parentId": None, "childrenIds": ["answer"], "timestamp": now},
        "answer": {"id": "answer", "role": "assistant", "content": "Use red paper.", "output": output("Use red paper."), "model": MODEL["id"], "parentId": "question", "childrenIds": [], "timestamp": now, "done": True}
    }})

def envelope():
    return {"id": CHAT_ID, "title": CHAT["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "chat": CHAT}

async def emit(kind, payload, target=None, chat=None):
    await sio.emit("events", {"chat_id": chat or CHAT_ID, "message_id": target or TARGET, "data": {"type": kind, "data": payload}})

async def correct(text):
    node = CHAT["history"]["messages"][TARGET]
    node.update(originalContent=node["content"], content=text)
    # Native text-only outlet edits can retain the previous output array.
    await emit("chat:outlet", {"messages": [{"id": TARGET, "role": "assistant", "content": text}]})

@sio.on("user-join")
async def join(sid, data): return {"status": True}

async def handle(request):
    global ACTIVE, TARGET
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/correct": await correct(body.get("text", "Use tan paper.")); result = {"ok": True}
    elif path == "/_test/wrong-chat":
        await emit("chat:outlet", {"messages": [{"id": TARGET, "content": "Wrong chat correction."}]}, chat="unrelated-chat")
        result = {"ok": True}
    elif path == "/_test/finish":
        if ACTIVE:
            node = CHAT["history"]["messages"][TARGET]
            text = "Fold each corner gently. " * 80 + "ORIGINAL-END"
            node.update(content=text, output=output(text), done=True)
            await emit("chat:completion", {"content": text, "output": node["output"], "done": True})
            await asyncio.sleep(0.1)
            await correct("The corrected craft uses blue paper.")
            ACTIVE = None
        result = {"ok": True}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-outlet-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-outlet-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k != "chat"}]
    elif path == "/api/v1/chats/" + CHAT_ID:
        if "chat" in body: CHAT.update(copy.deepcopy(body["chat"]))
        result = envelope()
    elif path == "/api/chat/completions":
        ACTIVE = body; TARGET = body["id"]
        await emit("chat:completion", {"content": "Planning another paper craft.", "done": False})
        result = {"task_id": "synthetic-task"}
    elif path.startswith("/api/tasks"): result = {"tasks": ["synthetic-task"] if ACTIVE else []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
