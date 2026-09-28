"""Fresh model/chat variables fixture. Loopback only; no provider or private data."""
import asyncio
import copy
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "variables-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
FIELDS = [
    {"key": "topic", "label": "Craft Topic", "required": True},
    {"key": "copies", "label": "Copies", "type": "number", "min": 0, "max": 10, "default": 3},
    {"key": "scale", "label": "Scale", "type": "range", "min": 0, "max": 1, "step": 0.25, "default": 0.5},
    {"key": "material", "label": "Material", "type": "select", "options": ["Paper", "Cardboard"], "default": "Paper"},
    {"key": "include_title", "label": "Include Title", "type": "checkbox", "default": False},
]
MODEL = {"id": "variables-demo", "name": "Craft Demo", "owned_by": "openai", "info": {"meta": {"chat_variables_schema": {"fields": FIELDS}}}}
CHATS = {}
STATE = {}

def reset():
    STATE.clear(); STATE.update(writes=0, completions=[], creates=[], fail=False, fail_create=False)
    CHATS.clear()
    now = int(time.time())
    CHATS["synthetic-variables"] = {"id": "synthetic-variables", "title": "Synthetic craft planning", "variables": {"other_model": {"preserved": [1, 2]}}, "chat": {
        "title": "Synthetic craft planning", "models": [MODEL["id"]], "history": {"currentId": "answer", "messages": {
            "question": {"id": "question", "role": "user", "content": "What can we fold from paper?", "parentId": None, "childrenIds": ["answer"], "timestamp": now},
            "answer": {"id": "answer", "role": "assistant", "model": MODEL["id"], "content": "Try a paper star.", "parentId": "question", "childrenIds": [], "timestamp": now, "done": True}
        }}
    }}

def envelope(item):
    return {"user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), **copy.deepcopy(item)}

async def finish(body):
    await asyncio.sleep(0.3)
    chat_id, message_id = body.get("chat_id"), body["id"]
    text = "The synthetic craft plan is ready."
    if chat_id in CHATS:
        chat = CHATS[chat_id]["chat"]
        node = chat["history"]["messages"].setdefault(message_id, {"id": message_id, "role": "assistant", "model": MODEL["id"], "parentId": body.get("parent_id"), "childrenIds": []})
        node.update(content=text, done=True)
    await sio.emit("events", {"chat_id": chat_id, "message_id": message_id, "data": {"type": "chat:completion", "data": {"content": text, "done": True}}})

@sio.on("user-join")
async def join(sid, data): return {"status": True}

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "chats": CHATS}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-variables-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-variables-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/models/model": result = {"id": MODEL["id"], "name": MODEL["name"], **MODEL["info"]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope(item).items() if k not in ("chat", "variables")} for item in CHATS.values()]
    elif path == "/api/v1/chats/new":
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        STATE["creates"].append(copy.deepcopy(body))
        if STATE["fail_create"]: return web.json_response({"detail": "Synthetic create failed."}, status=503)
        chat_id = "synthetic-new-" + str(len(STATE["creates"]))
        CHATS[chat_id] = {"id": chat_id, "title": body["chat"]["title"], "chat": copy.deepcopy(body["chat"]), "variables": copy.deepcopy(body.get("variables", {}))}
        result = envelope(CHATS[chat_id])
    elif path.startswith("/api/v1/chats/") and path.split("/")[-1] in CHATS:
        item = CHATS[path.split("/")[-1]]
        if "variables" in body:
            assert request.headers.get("Authorization") == "Bearer synthetic-token"
            assert body.get("chat") == {}, "Variable-only saves must not replace chat history"
            STATE["writes"] += 1
            if STATE["fail"]: return web.json_response({"detail": "Synthetic variables save failed."}, status=503)
            item["variables"] = copy.deepcopy(body["variables"])
        if "chat" in body: item["chat"].update(copy.deepcopy(body["chat"]))
        result = envelope(item)
    elif path == "/api/chat/completions":
        STATE["completions"].append(copy.deepcopy(body))
        values = CHATS.get(body.get("chat_id"), {}).get("variables", body.get("chat_variables", {}))
        if not values.get("topic"): return web.json_response({"detail": "Synthetic model requires Craft Topic."}, status=400)
        asyncio.create_task(finish(body)); result = {"task_id": "synthetic-task"}
    elif path.startswith("/api/tasks"): result = {"tasks": []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
