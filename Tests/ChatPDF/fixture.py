"""Fresh synthetic chat and a missing legacy PDF route. Loopback only."""
import time
from aiohttp import web

app = web.Application()
USER = {"id": "pdf-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "pdf-demo", "name": "Craft Demo", "owned_by": "openai"}
REQUESTS = []
now = int(time.time())
CHAT = {"id": "synthetic-pdf", "title": "Paper craft guide", "models": [MODEL["id"]], "history": {"currentId": "answer", "messages": {
    "question": {"id": "question", "role": "user", "content": "Write a guide to folding paper stars.", "parentId": None, "childrenIds": ["answer"], "timestamp": now},
    "answer": {"id": "answer", "role": "assistant", "model": MODEL["id"], "content": "# Paper stars\n\n"
        + "\n\n".join(f"Step {i}: Fold a corner toward the center, then press the crease flat. Keep the edges aligned and unfold gently." for i in range(1, 41))
        + "\n\nThe synthetic guide is complete.", "parentId": "question", "childrenIds": [], "timestamp": now, "done": True}
}}}

def envelope():
    return {"id": CHAT["id"], "title": CHAT["title"], "user_id": USER["id"], "created_at": now, "updated_at": now, "chat": CHAT}

async def handle(request):
    path = request.path.rstrip("/")
    result = []
    if path == "/_test/reset": REQUESTS.clear(); return web.json_response({"ok": True})
    if path == "/_test/state": return web.json_response({"requests": REQUESTS})
    REQUESTS.append(request.method + " " + path)
    if path == "/api/v1/utils/pdf": return web.json_response({"detail": "Not Found"}, status=404)
    if path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-pdf-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-pdf-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k != "chat"}]
    elif path == "/api/v1/chats/" + CHAT["id"]: result = envelope()
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
