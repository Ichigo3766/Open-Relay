"""Synthetic Socket.IO integration fixture; no external model or tool is called."""
import asyncio
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
app = web.Application()
sio.attach(app, socketio_path="ws/socket.io")
sessions = set()
USER = {"id": "demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "rpc-demo", "name": "RPC Demo", "owned_by": "openai"}


@sio.on("user-join")
async def join(sid, data):
    sessions.add(sid)
    return {"status": True}


@sio.on("disconnect")
async def disconnect(sid, reason):
    sessions.discard(sid)


async def probe(request):
    for _ in range(40):
        if sessions: break
        await asyncio.sleep(0.25)
    if len(sessions) != 1:
        return web.json_response({"error": "Connect one isolated simulator first"}, status=409)
    sid = next(iter(sessions))
    results = {}
    for kind in ("execute", "execute:python", "execute:tool", "request:chat:completion"):
        try:
            result = await sio.call("events", {
                "chat_id": "unopened-synthetic-chat", "message_id": "synthetic-message",
                "data": {"type": kind, "data": {"session_id": sid, "code": "return 7;",
                         "name": "demo_tool", "channel": "synthetic-channel"}}}, to=sid, timeout=3)
        except socketio.exceptions.TimeoutError:
            result = {"timeout": True}
        results[kind] = result
    return web.json_response(results)


async def handle(request):
    path = request.path.rstrip("/")
    result = []
    if path in ("", "/health"): result = {"status": True}
    elif path == "/api/config":
        result = {"status": True, "version": "0.0.0-rpc-fixture", "name": "RPC Demo",
                  "features": {"auth": True, "enable_login_form": True, "enable_signup": False,
                               "enable_websocket": True, "enable_channels": False},
                  "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-rpc-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path.startswith("/api/v1/models/model"): result = MODEL
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)


app.router.add_post("/_test/probe", probe)
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
