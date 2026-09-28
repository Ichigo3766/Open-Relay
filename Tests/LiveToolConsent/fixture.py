"""Synthetic loopback socket fixture. Requires aiohttp and python-socketio."""
import asyncio
import json
import time
import uuid
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "consent-demo", "name": "Tool Consent Demo", "owned_by": "openai"}
CHATS, REPLIES, RUNNING = {}, [], set()
RESOLVES = []
SCENARIO = "consent"
QUESTIONS = {"allow_other": True, "timeout_ms": 120000, "questions": [
    {"id": "color", "header": "Paper color", "question": "Which paper color?", "allow_other": False,
     "options": [{"label": "Blue", "description": "A blue sky"}, {"label": "Green", "description": "A green field"}]}
]}


@sio.on("user-join")
async def join(sid, data):
    return {"status": True}


async def generate(body):
    chat_id, message_id = body["chat_id"], body["id"]
    chat = CHATS[chat_id]["chat"]
    history = chat.setdefault("history", {"messages": {}})
    node = history["messages"].setdefault(message_id, {
        "id": message_id, "role": "assistant", "parentId": body.get("parent_id"),
        "childrenIds": [], "model": MODEL["id"], "timestamp": int(time.time()),
    })
    node.update(content="Waiting for your tool response.", done=False)
    history["currentId"] = message_id

    def event(kind, payload):
        return {"chat_id": chat_id, "message_id": message_id, "session_id": body["session_id"],
                "data": {"type": kind, "data": payload}}

    await sio.emit("events", event("chat:message", {"content": node["content"]}), to=body["session_id"])
    if SCENARIO in ("ask", "saved"):
        if SCENARIO == "saved":
            node.update(done=True, output=[{"type": "function_call", "name": "ask_user", "call_id": "demo-call", "status": "pending", "arguments": json.dumps(QUESTIONS)}])
            await sio.emit("events", event("chat:completion", {"output": node["output"], "done": True}), to=body["session_id"])
            return
        answer = await sio.call("events", event("request:user_input", QUESTIONS), to=body["session_id"], timeout=180)
        REPLIES.append({"type": "ask_user", "value": answer})
        node.update(content="The synthetic tool received your answer.", done=True)
        await sio.emit("events", event("chat:completion", {"content": node["content"], "done": True}), to=body["session_id"])
        return
    for kind, payload in [
        ("confirmation", {"title": "Run the demo tool?", "message": "This synthetic tool will count three paper stars. Continue?"}),
        ("input", {"title": "Name the paper sky", "message": "Choose a label for this invented example.", "value": "Paper sky", "placeholder": "Sky label"}),
    ]:
        try:
            answer = await sio.call("events", event(kind, payload), to=body["session_id"], timeout=180)
        except socketio.exceptions.TimeoutError:
            return
        REPLIES.append({"type": kind, "value": answer})
    await sio.emit("events", event("notification", {"type": "success", "content": "Demo tool finished"}), to=body["session_id"])
    node.update(content="The synthetic tool received both responses.", done=True)
    await sio.emit("events", event("chat:completion", {"content": node["content"], "done": True}), to=body["session_id"])


async def handle(request):
    global SCENARIO
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset":
        for task in tuple(RUNNING): task.cancel()
        CHATS.clear(); REPLIES.clear(); RESOLVES.clear()
        SCENARIO = body.get("scenario", "consent")
        result = {"ok": True}
    elif path == "/_test/state": result = {"replies": REPLIES, "resolves": RESOLVES}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config":
        result = {"status": True, "version": "0.0.0-consent-fixture", "name": "Tool Consent Demo",
                  "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                               "enable_websocket": True, "enable_channels": False},
                  "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-consent-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/chats/new":
        chat = body["chat"]
        identifier = chat.get("id") or str(uuid.uuid4())
        chat["id"] = identifier
        result = {"id": identifier, "title": "Synthetic consent", "user_id": USER["id"],
                  "created_at": int(time.time()), "updated_at": int(time.time()), "chat": chat}
        CHATS[identifier] = result
    elif path in ("/api/v1/chats", "/api/v1/chats/list"):
        result = [{k: v for k, v in item.items() if k != "chat"} for item in CHATS.values()]
    elif path.endswith("/resolve"):
        RESOLVES.append(body)
        if SCENARIO != "saved" or len(RESOLVES) == 1:
            return web.json_response({"detail": "Synthetic response failure"}, status=503)
        chat = CHATS.get(path.split("/")[4], {}).get("chat", {})
        node = chat.get("history", {}).get("messages", {}).get(path.split("/")[6], {})
        node["output"] = []
        node["content"] = "The saved response was received."
        result = {"status": True}
    elif path.startswith("/api/v1/chats/"):
        result = CHATS.get(path.split("/")[4], {})
        if "chat" in body and result: result["chat"].update(body["chat"])
    elif path == "/api/chat/completions":
        task = asyncio.create_task(generate(body))
        RUNNING.add(task)
        task.add_done_callback(RUNNING.discard)
        result = {"task_id": "synthetic-task"}
    elif path.startswith("/api/tasks"):
        result = {"tasks": ["synthetic-task"] if RUNNING else []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)


app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
