"""Fresh calendar API fixture. Loopback only; never contacts a real server."""
import copy
from datetime import datetime, timezone, timedelta
from aiohttp import web

app = web.Application()
USER = {"id": "calendar-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "calendar-demo", "name": "Craft Demo", "owned_by": "openai"}
CALENDAR = {"id": "craft-calendar", "user_id": USER["id"], "name": "Crafts", "color": "#3b82f6", "is_default": True, "is_system": False}
STATE, EVENTS = {}, {}

def reset():
    STATE.clear(); STATE.update(writes=[], fail=False, fail_fetch=False)
    EVENTS.clear()
    start = int((datetime.now(timezone.utc).replace(hour=18, minute=0, second=0, microsecond=0) - timedelta(days=7)).timestamp() * 1_000_000_000)
    EVENTS["paper-series"] = {"id": "paper-series", "calendar_id": CALENDAR["id"], "user_id": USER["id"], "title": "Paper workshop", "start_at": start,
        "end_at": start + 3_600_000_000_000, "all_day": False, "rrule": "FREQ=WEEKLY;BYDAY=MO;COUNT=8", "description": "Fold a paper star.",
        "location": "Craft room", "color": "#ffaa00", "is_cancelled": False,
        "meta": {"alert_minutes": -1, "external_marker": "preserve"}, "data": {"external": "preserve"},
        "attendees": [{"user_id": "craft-guest", "status": "accepted"}]}

def visible():
    result = copy.deepcopy(list(EVENTS.values()))
    for event in result:
        if event["id"] == "paper-series":
            event["instance_id"] = "paper-series:synthetic-instance"
            event["start_at"] += 7 * 86_400_000_000_000
            if event.get("end_at") is not None: event["end_at"] += 7 * 86_400_000_000_000
    return result

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.method == "POST" and request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "events": EVENTS}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-calendar-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-calendar-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/calendars": result = [CALENDAR]
    elif path == "/api/v1/calendars/events": result = visible()
    elif path.startswith("/api/v1/calendars/events/"):
        assert request.headers.get("Authorization") == "Bearer synthetic-token"
        if request.method == "GET":
            if STATE["fail_fetch"]: return web.json_response({"detail": "Synthetic unavailable event."}, status=503)
            result = EVENTS.get(path.split("/")[-1])
            if result is None: return web.json_response({"detail": "Missing fixture event."}, status=404)
        else:
            STATE["writes"].append({"path": path, "body": copy.deepcopy(body)})
            if STATE["fail"]: return web.json_response({"detail": "Synthetic save failed."}, status=503)
            if path.endswith("/create"):
                event_id = "created-craft-" + str(len(STATE["writes"]))
                EVENTS[event_id] = {"id": event_id, "user_id": USER["id"], "is_cancelled": False, **body}
            else:
                event_id = path.split("/")[-2]
                if event_id not in EVENTS: return web.json_response({"detail": "Use the series ID."}, status=404)
                event = EVENTS[event_id]
                for key, value in body.items():
                    if key in ("data", "meta") and value is not None: event[key] = {**event.get(key, {}), **value}
                    else: event[key] = copy.deepcopy(value)
            result = EVENTS[event_id]
    elif request.method == "POST": result = {"status": True}
    return web.json_response(result)

reset()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
