"""Synthetic Relay API and browser/provider handoff. Loopback only, no real OAuth."""
import asyncio
import copy
import html
import time
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])

@sio.on("user-join")
async def join(sid, data): return {"status": True}

USER = {"id": "oauth-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
TOOL = {"id": "server:mcp:paper", "name": "Paper Tools", "description": "Synthetic paper craft integration.", "authenticated": False}
CHAT_ID = "synthetic-craft-chat"
MODEL = {"id": "craft-demo", "name": "Craft Demo", "owned_by": "openai", "info": {"meta": {"toolIds": [TOOL["id"]]}}}
STATE = {}
CHAT = {}

def reset():
    STATE.clear(); STATE.update(connected=False, fail=False, completions=0, browser_requests=0, provider_requests=0, leaked_headers=False)
    CHAT.clear(); CHAT.update(id=CHAT_ID, title="Paper folding", models=[MODEL["id"]], history={"currentId": "a", "messages": {
        "q": {"id": "q", "role": "user", "content": "Describe a paper fold.", "childrenIds": ["a"], "parentId": None, "timestamp": int(time.time())},
        "a": {"id": "a", "role": "assistant", "content": "Fold the paper in half.", "childrenIds": [], "parentId": "q", "model": MODEL["id"], "timestamp": int(time.time()), "done": True}}})

def envelope():
    return {"id": CHAT_ID, "title": CHAT["title"], "user_id": USER["id"], "created_at": int(time.time()), "updated_at": int(time.time()), "chat": CHAT}

def page(title, content):
    return web.Response(text=f'<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title></head><body style="font:20px system-ui;padding:24px"><h1>{title}</h1>{content}</body></html>', content_type="text/html")

def browser_request(request, provider=False):
    STATE["provider_requests" if provider else "browser_requests"] += 1
    if request.headers.get("Authorization") or request.headers.get("X-Demo-Secret"):
        STATE["leaked_headers"] = True

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.content_type == "application/json" else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/state": result = STATE
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/auth":
        browser_request(request)
        redirect = html.escape(request.query["redirect"], quote=True)
        return page("Demo sign-in", f'<p>This is an isolated test account.</p><form method="post" action="/fixture-login"><input type="hidden" name="redirect" value="{redirect}"><button>Sign in to Demo</button></form>')
    elif path == "/fixture-login":
        browser_request(request)
        fields = await request.post()
        response = web.HTTPFound(fields["redirect"])
        response.set_cookie("fixture_session", "synthetic-browser-session", httponly=True)
        return response
    elif path == "/oauth/clients/mcp:paper/authorize":
        browser_request(request)
        assert request.cookies.get("fixture_session") == "synthetic-browser-session"
        return web.HTTPFound("http://127.0.0.1:18192/consent")
    elif path == "/oauth/callback":
        browser_request(request)
        assert request.cookies.get("fixture_session") == "synthetic-browser-session"
        STATE["connected"] = True
        return page("Authorization complete", "<p>Return to Open Relay and check the connection.</p>")
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-oauth-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": True, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-oauth-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/models/model": result = {"id": MODEL["id"], "name": MODEL["name"], "meta": MODEL["info"]["meta"], "params": {}}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/tools":
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        if STATE["fail"]: return web.json_response({"detail": "Synthetic failure"}, status=503)
        result = [{**TOOL, "authenticated": STATE["connected"]}]
    elif path in ("/api/v1/chats", "/api/v1/chats/list"): result = [{k: v for k, v in envelope().items() if k != "chat"}]
    elif path in ("/api/v1/chats/" + CHAT_ID, "/api/v1/chats/new"):
        if "chat" in body: CHAT.update(copy.deepcopy(body["chat"]))
        result = envelope()
    elif path == "/api/chat/completions":
        STATE["completions"] += 1
        STATE["last_tools"] = body.get("tool_ids", [])
        target = body["id"]
        content = "Fold the corners inward."
        CHAT["history"]["messages"][target].update(content=content, done=True)
        await sio.emit("events", {"chat_id": CHAT_ID, "message_id": target, "data": {"type": "chat:completion", "data": {"content": content, "done": True}}})
        result = {"task_id": "synthetic-task"}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

async def provider(request):
    browser_request(request, provider=True)
    if request.path == "/allow": return web.HTTPFound("http://127.0.0.1:18191/oauth/callback")
    return page("Paper Provider", '<p>Allow this synthetic account to use Paper Tools?</p><a href="/allow">Allow Paper Tools</a>')

async def main():
    reset()
    for port, handler in [(18191, handle), (18192, provider)]:
        app = web.Application()
        if port == 18191: sio.attach(app, socketio_path="ws/socket.io")
        app.router.add_route("*", "/{path:.*}", handler)
        runner = web.AppRunner(app, access_log=None); await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", port).start()
    print("Synthetic OAuth fixture ready", flush=True)
    await asyncio.Event().wait()

if __name__ == "__main__": asyncio.run(main())
