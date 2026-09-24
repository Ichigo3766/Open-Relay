"""Loopback-only synthetic streaming fixture. Never imports or contacts Open WebUI."""
import asyncio
import json
import time
import uuid
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "fixture", "name": "Fixture Model", "owned_by": "openai"}
CHATS = {}
METRICS = []
MODE = "modern-thinking"
RUNNING = set()
PARAGRAPH = "The imaginary observatory has a copper telescope and a blue notebook. Seven paper stars mark the map. The telescope points toward a painted moon while the notebook records an invented description."
ANSWER = "Here is the synthetic observatory report.\n\n" + "\n\n".join(f"**Observation {n}**\n\n{PARAGRAPH}" for n in range(1, 7))
THINKING = "\n\n".join(f"Invented planning note {n}: compare the paper stars with the painted moon." for n in range(400))

def mark(event, **values):
    value = {"time": time.monotonic(), "wall_time": time.time(), "event": event, **values}
    METRICS.append(value)
    print(json.dumps(value), flush=True)

@sio.event
async def connect(sid, environ, auth):
    mark("socket_connected")

@sio.on("user-join")
async def user_join(sid, data):
    mark("user_joined")
    return {"status": True, "sid": sid}

@sio.on("usage")
async def usage(sid, data):
    return True

async def generate(body, mode):
    answer = PARAGRAPH if mode == "slow-thinking" else ANSWER
    if mode == "long-code":
        answer = "Synthetic code sample.\n\n```swift\n" + "\n".join(f"let star{n} = {n} // invented observation" for n in range(160)) + "\n```\n\nFinished synthetic code."
    if mode == "mixed":
        answer = "Synthetic formatting.\n\n" + "\n\n".join(f"1. Entry {n}. {PARAGRAPH}" for n in range(8)) + "\n\n~~~text\nInvented tilde fence.\n\nMore code.\n~~~\n\nUnicode: 🔭 café 星. Math: $x^2$.\n\n[Guide](https://example.com)."
    if mode in ("long", "scrolling"):
        answer = "\n\n".join(f"Section {n}. {PARAGRAPH}" for n in range(80))
    interval = 0.5 if mode == "slow-thinking" else 0.02 if mode in ("long", "long-code", "mixed") else 0.1
    chunk = 200 if mode in ("long", "long-code") else 20
    if mode == "scrolling": chunk = 80
    chat_id, message_id = body["chat_id"], body["id"]
    entry = CHATS[chat_id]
    history = entry["chat"].setdefault("history", {"messages": {}})
    node = history["messages"].setdefault(message_id, {"id": message_id, "role": "assistant", "parentId": body.get("parent_id"), "childrenIds": [], "model": "fixture", "timestamp": int(time.time())})
    node.update(content="", done=False)
    history["currentId"] = message_id
    async def emit(kind, payload):
        await sio.emit("events", {"chat_id": chat_id, "message_id": message_id, "session_id": body.get("session_id"), "data": {"type": kind, "data": payload}})
    mark("request_started", mode=mode, has_socket_session=bool(body.get("session_id")))
    if mode in ("modern-thinking", "slow-thinking"):
        await emit("status", {"action": "thinking", "description": "Thinking about an imaginary observatory…", "done": False})
        for n in range(60):
            await emit("response:completion", {"type": "response.reasoning_text.delta", "delta": THINKING[n * 400:(n + 1) * 400]})
            await asyncio.sleep(0.1)
        await emit("status", {"action": "thinking", "description": "Finished thinking", "done": True})
    mark("answer_start", answer_chars=len(answer))
    for end in range(chunk, len(answer) + chunk, chunk):
        start = end - chunk
        delta = answer[start:end]
        node["content"] += delta
        await emit("response:completion", {"type": "response.output_text.delta", "delta": delta})
        await asyncio.sleep(interval)
    mark("answer_sent")
    output = []
    if mode in ("modern-thinking", "slow-thinking"):
        output.append({"id": "synthetic-reasoning", "type": "reasoning", "status": "completed", "content": [{"type": "output_text", "text": THINKING}]})
    output.append({"id": "synthetic-answer", "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": answer}]})
    node.update(done=True, output=output)
    if mode in ("modern-thinking", "slow-thinking"):
        node["content"] = '<details type="reasoning" done="true"><summary>Thinking</summary>\n' + THINKING + '\n</details>\n\n' + answer
    entry["chat"]["messages"] = list(history["messages"].values())
    mark("done_sent", final_chars=len(node["content"]))
    await emit("chat:completion", {"done": True, "output": output})
    await emit("chat:title", {"title": entry["title"]})

async def handle(request):
    global MODE
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    if path == "/fixture/metrics": return web.json_response(METRICS)
    if path == "/fixture/control":
        if request.method == "POST": MODE = body.get("mode", MODE)
        return web.json_response({"mode": MODE, "synthetic": True})
    if path in ("", "/health"): return web.json_response({"status": True})
    if path == "/api/config": return web.json_response({"status": True, "version": "0.0.0-fixture", "name": "Synthetic Streaming", "features": {"auth": True, "enable_login_form": True, "enable_signup": False, "enable_websocket": True}, "default_models": ["fixture"]})
    if path == "/api/version": return web.json_response({"version": "0.0.0-fixture"})
    if path == "/api/v1/auths": return web.json_response(USER)
    if path == "/api/v1/auths/signin": return web.json_response({**USER, "token": "synthetic-token", "token_type": "Bearer"})
    if path == "/api/models": return web.json_response({"data": [MODEL]})
    if path.startswith("/api/v1/models/model"): return web.json_response(MODEL)
    if path == "/api/v1/users/user/settings": return web.json_response({"ui": {}})
    if path == "/api/v1/users/user/permissions": return web.json_response({"chat": {"file_upload": True}})
    if path == "/api/v1/chats/new":
        chat = body["chat"]
        identifier = chat.get("id") or str(uuid.uuid4())
        chat["id"] = identifier
        chat["title"] = f"Synthetic {MODE} {len(CHATS) + 1}"
        entry = {"id": identifier, "title": chat["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "pinned": False, "archived": False, "chat": chat}
        CHATS[identifier] = entry
        return web.json_response(entry)
    if path in ("/api/v1/chats", "/api/v1/chats/list"):
        return web.json_response([{k: v for k, v in item.items() if k != "chat"} for item in CHATS.values()] if request.query.get("page", "1") == "1" else [])
    if path == "/api/v1/chats/pinned": return web.json_response([])
    if path.startswith("/api/v1/chats/"):
        identifier = path.split("/")[4]
        if identifier in CHATS:
            if request.method == "POST" and "chat" in body: CHATS[identifier]["chat"].update(body["chat"])
            return web.json_response(CHATS[identifier])
        return web.json_response({"detail": "Synthetic chat not found"}, status=404)
    if path == "/api/chat/completions":
        task = asyncio.create_task(generate(body, MODE))
        RUNNING.add(task)
        task.add_done_callback(RUNNING.discard)
        return web.json_response({"task_id": "synthetic-task"})
    if path == "/api/chat/completed": return web.json_response({"status": True})
    if path.startswith("/api/tasks/stop"):
        for task in list(RUNNING): task.cancel()
        mark("stopped")
        return web.json_response({"status": True})
    if path.startswith("/api/tasks"): return web.json_response({"tasks": ["synthetic-task"] if RUNNING else []})
    if request.method == "POST": return web.json_response({"status": True})
    return web.json_response([])

app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18188, access_log=None)
