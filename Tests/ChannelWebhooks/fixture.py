"""Synthetic channel/webhook server, with no upstream or provider connections."""
import copy
from aiohttp import web

app = web.Application()
USER = {"id": "craft-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
CHANNEL = {"id": "crafts", "user_id": USER["id"], "name": "Paper Crafts", "type": "", "is_manager": True,
           "write_access": True, "is_private": True, "created_at": 1760000000, "updated_at": 1760000000}
MODEL = {"id": "craft-demo", "name": "Craft Demo", "owned_by": "openai"}
STATE, HOOKS = {}, {}

def reset():
    STATE.clear(); STATE.update(writes=[], fail=False, denied=False)
    HOOKS.clear()
    HOOKS["paper-hook"] = {"id": "paper-hook", "channel_id": "crafts", "name": "Paper Bot", "token": "synthetic-secret",
        "profile_image_url": "data:image/png;base64,c3ludGhldGlj", "user_id": USER["id"], "created_at": 1760000000000000000,
        "updated_at": 1760000000000000000, "last_used_at": None}

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "hooks": HOOKS}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-webhook-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": True}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-webhook-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path in ("/api/v1/channels", "/api/v1/channels/list"): result = [CHANNEL]
    elif path == "/api/v1/channels/crafts": result = CHANNEL
    elif path in ("/api/v1/channels/crafts/members", "/api/v1/users/search"): result = {"users": [USER], "total": 1}
    elif path.startswith("/api/v1/channels/crafts/webhooks"):
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        if STATE["denied"]: return web.json_response({"detail": "Synthetic access denied."}, status=403)
        if request.method == "GET": result = list(HOOKS.values())
        else:
            STATE["writes"].append({"path": path, "body": copy.deepcopy(body), "method": request.method})
            if STATE["fail"]: return web.json_response({"detail": "Synthetic webhook save failed."}, status=503)
            if path.endswith("/delete"):
                result = HOOKS.pop(path.split("/")[-2], None) is not None
            elif path.endswith("/create"):
                hook_id = "created-paper-" + str(len(STATE["writes"]))
                HOOKS[hook_id] = {"id": hook_id, "channel_id": "crafts", "token": "synthetic-new-secret", **body}
                result = HOOKS[hook_id]
            else:
                hook = HOOKS[path.split("/")[-2]]
                hook.update(body)
                result = hook
    elif request.method != "GET": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
