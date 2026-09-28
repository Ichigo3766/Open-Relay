"""Synthetic loopback fixture; requires aiohttp and python-socketio."""
import asyncio
import time
import uuid
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "search-demo", "name": "Search Consent Demo", "owned_by": "openai",
         "info": {"meta": {"capabilities": {"web_search": True}, "defaultFeatureIds": ["web_search"]}}}
CHATS, REQUESTS, RUNNING = {}, [], set()
REQUIRED = True


@sio.on("user-join")
async def join(sid, data):
    return {"status": True}


async def generate(body):
    await asyncio.sleep(0.1)
    node = {"id": body["id"], "role": "assistant", "parentId": body.get("parent_id"),
            "childrenIds": [], "model": MODEL["id"], "timestamp": int(time.time()),
            "content": "The synthetic search request was received.", "done": True}
    history = CHATS[body["chat_id"]]["chat"].setdefault("history", {"messages": {}})
    history["messages"][node["id"]] = node
    history["currentId"] = node["id"]
    await sio.emit("events", {"chat_id": body["chat_id"], "message_id": node["id"], "session_id": body["session_id"],
                              "data": {"type": "chat:completion", "data": {"content": node["content"], "done": True}}}, to=body["session_id"])


async def handle(request):
    global REQUIRED
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset":
        for task in tuple(RUNNING): task.cancel()
        CHATS.clear(); REQUESTS.clear()
        REQUIRED = body.get("required", True)
        result = {"ok": True}
    elif path == "/_test/state": result = {"requests": REQUESTS, "chats": len(CHATS)}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config":
        result = {"status": True, "version": "0.0.0-search-fixture", "name": "Search Consent Demo",
                  "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                               "enable_websocket": True, "enable_channels": False, "enable_web_search": True,
                               "enable_web_search_confirmation": REQUIRED,
                               "web_search_confirmation_content": "This demo sends a search query to the configured provider. Continue?"},
                  "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-search-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path.startswith("/api/v1/models/model"): result = {"id": MODEL["id"], "name": MODEL["name"], **MODEL["info"]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/chats/new":
        chat = body["chat"]
        identifier = chat.get("id") or str(uuid.uuid4())
        chat["id"] = identifier
        result = {"id": identifier, "title": "Synthetic search", "user_id": USER["id"],
                  "created_at": int(time.time()), "updated_at": int(time.time()), "chat": chat}
        CHATS[identifier] = result
    elif path in ("/api/v1/chats", "/api/v1/chats/list"):
        result = [{k: v for k, v in item.items() if k != "chat"} for item in CHATS.values()]
    elif path.startswith("/api/v1/chats/"):
        result = CHATS.get(path.split("/")[4], {})
        if "chat" in body and result: result["chat"].update(body["chat"])
    elif path == "/api/chat/completions":
        REQUESTS.append(body)
        task = asyncio.create_task(generate(body))
        RUNNING.add(task); task.add_done_callback(RUNNING.discard)
        result = {"task_id": "synthetic-task"}
    elif path.startswith("/api/tasks"): result = {"tasks": ["synthetic-task"] if RUNNING else []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)


app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
