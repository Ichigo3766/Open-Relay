"""Synthetic context usage/compaction contract; loopback only, no model calls."""
import copy
import time
from aiohttp import web

app = web.Application()
USER = {"id": "context-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "context-demo", "name": "Craft Demo", "owned_by": "openai"}
STATE = {}
CHAT = {}

def reset():
    STATE.clear(); STATE.update(tokens=6000, posts=0, fail=False, enabled=True)
    CHAT.clear()
    now = int(time.time())
    CHAT.update(id="synthetic-context", title="Paper star planning", models=[MODEL["id"]], history={"currentId": "answer", "messages": {
        "question": {"id": "question", "role": "user", "content": "Plan a paper-star craft activity.", "parentId": None, "childrenIds": ["answer"], "timestamp": now},
        "answer": {"id": "answer", "role": "assistant", "model": MODEL["id"], "content": "Use five sheets and fold each corner toward the center.", "parentId": "question", "childrenIds": [], "timestamp": now, "done": True}
    }})

def usage():
    return {"tokens": STATE["tokens"], "estimated_tokens": STATE["tokens"], "threshold": 8000, "percent": round(STATE["tokens"] / 80), "source": "estimated"} if STATE["enabled"] else None

def envelope():
    return {"id": CHAT["id"], "title": CHAT["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "chat": CHAT, "context_usage": usage()}

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "checkpoint": CHAT["history"]["messages"]["answer"].get("contextSummary")}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-context-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-context-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k not in ("chat", "context_usage")}]
    elif path == "/api/v1/chats/" + CHAT["id"] + "/compact":
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        assert body.get("model") == MODEL["id"]
        STATE["posts"] += 1
        if STATE["fail"]: return web.json_response({"detail": "Synthetic compaction is unavailable."}, status=503)
        STATE["tokens"] = 2000
        CHAT["history"]["messages"]["answer"]["contextSummary"] = "The synthetic plan uses five paper sheets."
        result = {"ok": True, "compacted": True, "dropped_messages": 1, "kept_messages": 1, "summary_chars": 43, "context_usage": usage()}
    elif path == "/api/v1/chats/" + CHAT["id"]:
        if "chat" in body: CHAT.update(copy.deepcopy(body["chat"]))
        result = envelope()
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
