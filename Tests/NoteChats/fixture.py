"""Isolated native note-chat fixture. Synthetic content only; never forwards traffic."""
import asyncio
import copy
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "note-chat-demo", "name": "Note Chat Demo", "owned_by": "openai"}
SYSTEM = "CONTEXT:\nCurrent note id: paper\nThis chat is attached to the current note.\nFor edit requests: call view_note then replace_note_content."
CONTENT = "# Folding checklist\n\nStart with a square sheet. Fold the edges inward. Add a paper handle."
CHATS = {}; REQUESTS = []; COMPLETIONS = []; FAIL_CREATE = False; FAIL_LIST = False; UNSAVED = False
DOWNLOADS = []; RESPONSE_GATE = asyncio.Event(); GENERATION = 0

def create(chat_id, title="Chat", saved=False):
    history = {"messages": {}, "currentId": None}
    if saved:
        history = {"currentId": "answer", "messages": {
            "question": {"id": "question", "role": "user", "content": "What kind of paper should I use?", "parentId": None, "childrenIds": ["answer"]},
            "answer": {"id": "answer", "role": "assistant", "content": "A square of lightweight craft paper folds easily.", "model": MODEL["id"], "parentId": "question", "childrenIds": [], "done": True}}}
    CHATS[chat_id] = {"id": chat_id, "title": title, "user_id": USER["id"],
                     "created_at": int(time.time()), "updated_at": int(time.time()),
                     "meta": {"internal": True, "type": "note", "note_id": "paper"},
                     "chat": {"id": chat_id, "title": title, "models": [MODEL["id"]],
                              "params": {"system": SYSTEM}, "history": history, "messages": [], "tags": []}}
    return CHATS[chat_id]

def reset():
    global CONTENT, FAIL_CREATE, FAIL_LIST, UNSAVED, GENERATION
    GENERATION += 1
    CHATS.clear(); REQUESTS.clear(); COMPLETIONS.clear()
    DOWNLOADS.clear(); RESPONSE_GATE.set()
    FAIL_CREATE = FAIL_LIST = UNSAVED = False
    CONTENT = "# Folding checklist\n\nStart with a square sheet. Fold the edges inward. Add a paper handle."
    create("saved-note-chat", "Paper choices", saved=True)

def note():
    return {"id": "paper", "title": "Paper Lanterns", "user_id": USER["id"], "write_access": True,
            "created_at": 1780000000000000000, "updated_at": 1780000000000000000,
            "data": {"content": {"md": CONTENT if not UNSAVED else "Different server text."}}}

@sio.on("user-join")
async def join(sid, data): return {"status": True}

async def complete(body, generation):
    global CONTENT
    await RESPONSE_GATE.wait()
    await asyncio.sleep(0.4)
    if generation != GENERATION: return
    chat_id = body["chat_id"]; message_id = body["id"]
    answer = "The checklist now has two steps."
    CONTENT = "# Folding checklist\n\n1. Fold a square sheet.\n2. Add a paper handle."
    history = CHATS[chat_id]["chat"]["history"]
    history["messages"][message_id].update(content=answer, done=True)
    await sio.emit("events", {"chat_id": chat_id, "message_id": message_id,
                              "data": {"type": "chat:completion", "data": {"content": answer, "done": True}}})

async def handle(request):
    global FAIL_CREATE, FAIL_LIST, UNSAVED
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {}
    elif path == "/_test/state": result = {"requests": REQUESTS, "completions": COMPLETIONS, "chat_count": len(CHATS), "downloads": DOWNLOADS}
    elif path == "/_test/fail-create": FAIL_CREATE = True; result = {}
    elif path == "/_test/fail-list": FAIL_LIST = True; result = {}
    elif path == "/_test/unsaved": UNSAVED = True; result = {}
    elif path == "/_test/hold-response": RESPONSE_GATE.clear(); result = {}
    elif path == "/_test/finish-response": RESPONSE_GATE.set(); result = {}
    elif path == "/_test/link":
        CHATS["saved-note-chat"]["chat"]["history"]["messages"]["answer"]["content"] = "Open the [folding guide](http://127.0.0.1:18191/api/v1/files/guide/content)."
        result = {}
    elif path == "/api/v1/files/guide/content":
        if request.headers.get("Authorization") != "Bearer synthetic-token": raise web.HTTPUnauthorized()
        DOWNLOADS.append("guide")
        return web.Response(text="Fold a square sheet, then add a paper handle.", content_type="text/plain")
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-note-chat-fixture", "features": {
        "auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False, "enable_notes": True}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-note-chat-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/models/model": result = {**MODEL, "params": {"function_calling": "native"}, "meta": {"capabilities": {"builtin_tools": True}}}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path.startswith("/api/v1/notes"):
        if request.headers.get("Authorization") != "Bearer synthetic-token": raise web.HTTPUnauthorized()
        if path == "/api/v1/notes": result = [note()]
        elif path == "/api/v1/notes/paper": result = note()
        elif path == "/api/v1/notes/paper/chat":
            REQUESTS.append({"method": request.method, "path": path, "authenticated": True})
            if request.method == "POST":
                if FAIL_CREATE:
                    FAIL_CREATE = False
                    return web.json_response({"detail": "Synthetic creation failure"}, status=503)
                result = create("note-chat-" + str(len(CHATS)), "New note chat")
            else: result = next(iter(CHATS.values()))
        elif path == "/api/v1/notes/paper/chats":
            REQUESTS.append({"method": request.method, "path": path, "authenticated": True})
            if FAIL_LIST:
                FAIL_LIST = False
                return web.json_response({"detail": "Synthetic history failure"}, status=503)
            result = list(CHATS.values())
    elif path.startswith("/api/v1/chats/") and path.split("/")[-1] in CHATS:
        chat_id = path.split("/")[-1]
        if request.method == "DELETE": del CHATS[chat_id]; result = True
        else:
            if "chat" in body: CHATS[chat_id]["chat"].update(copy.deepcopy(body["chat"]))
            result = CHATS[chat_id]
    elif path == "/api/v1/chats/new":
        return web.json_response({"detail": "Note chats must use the native Notes endpoint"}, status=400)
    elif path == "/api/chat/completions":
        chat_id = body.get("chat_id")
        valid = (request.headers.get("Authorization") == "Bearer synthetic-token" and chat_id in CHATS
                 and body.get("params", {}).get("system") == SYSTEM)
        COMPLETIONS.append({"valid": valid, "chat_id": chat_id})
        if not valid: return web.json_response({"error": "Missing native note context"}, status=400)
        asyncio.create_task(complete(body, GENERATION))
        result = {"task_id": "synthetic-note-task"}
    elif path.startswith("/api/tasks"): result = {"tasks": []}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
