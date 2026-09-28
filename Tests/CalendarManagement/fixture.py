"""Invented calendar records, served only on loopback. No upstream connections."""
import copy
from aiohttp import web

app = web.Application()
USER = {"id": "calendar-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "calendar-demo", "name": "Craft Demo", "owned_by": "openai"}
STATE, CALENDARS = {}, {}

def calendar(id, name, **extra):
    return {"id": id, "user_id": USER["id"], "name": name, "color": "#3b82f6", "is_default": False,
            "is_system": False, "data": {"preserve": "data"}, "meta": {"preserve": "meta"},
            "access_grants": [{"principal_type": "user", "principal_id": "craft-guest", "permission": "read"}], **extra}

def reset():
    STATE.clear(); STATE.update(writes=[], fail=False)
    CALENDARS.clear()
    CALENDARS["shared"] = calendar("shared", "Shared Templates", user_id="craft-guest", is_default=True)
    CALENDARS["crafts"] = calendar("crafts", "Crafts", is_default=True)
    CALENDARS["workshops"] = calendar("workshops", "Workshops", color="#22c55e")
    CALENDARS["__scheduled_tasks__"] = calendar("__scheduled_tasks__", "Scheduled Tasks", is_system=True)

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "calendars": CALENDARS}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-calendar-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-calendar-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/calendars": result = list(CALENDARS.values())
    elif path == "/api/v1/calendars/events": result = []
    elif path.startswith("/api/v1/calendars/"):
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        STATE["writes"].append({"path": path, "body": copy.deepcopy(body), "method": request.method})
        if STATE["fail"]: return web.json_response({"detail": "Synthetic save unavailable."}, status=503)
        if path.endswith("/create"):
            id = "new-craft-" + str(len(STATE["writes"]))
            CALENDARS[id] = calendar(id, **body)
            result = CALENDARS[id]
        else:
            id = path.split("/")[-2]
            if id not in CALENDARS: return web.json_response({"detail": "Missing calendar."}, status=404)
            item = CALENDARS[id]
            if item["is_system"]: return web.json_response({"detail": "System calendar."}, status=400)
            if path.endswith("/delete"):
                if item["is_default"]: return web.json_response({"detail": "Default calendar."}, status=400)
                del CALENDARS[id]; result = {"status": True}
            elif path.endswith("/default"):
                for value in CALENDARS.values():
                    if value["user_id"] == USER["id"]: value["is_default"] = value["id"] == id
                result = item
            else:
                item.update(body); result = item
    elif request.method != "GET": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
