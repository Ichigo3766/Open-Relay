"""Fresh synthetic invitations. Loopback only; never contacts an upstream server."""
import asyncio
import copy
from datetime import datetime, timezone
from aiohttp import web

USER = {"id": "calendar-demo-user", "name": "Demo", "email": "demo@example.test", "role": "admin"}
MODEL = {"id": "calendar-demo", "name": "Craft Demo", "owned_by": "openai"}
CALENDAR = {"id": "crafts", "user_id": "organizer", "name": "Crafts", "color": "#3b82f6", "is_default": True, "is_system": False}
STATE, EVENTS = {}, {}

def reset():
    STATE.clear()
    STATE.update(writes=[], fail=False, delay=0, malformed=False)
    EVENTS.clear()
    # Use the current instant so the event is "today" across time zones/UTC midnight.
    start = int(datetime.now(timezone.utc).replace(second=0, microsecond=0).timestamp() * 1_000_000_000)
    for id, title, invited in [("paper-series", "Paper workshop", True), ("public-event", "Open craft room", False)]:
        EVENTS[id] = {"id": id, "calendar_id": "crafts", "user_id": "organizer", "title": title,
                      "start_at": start, "end_at": start + 3_600_000_000_000, "all_day": False,
                      "rrule": "FREQ=WEEKLY" if invited else None, "is_cancelled": False,
                      "description": "Fold a paper star.", "location": "Craft room",
                      "attendees": [{"id": "invite", "event_id": id, "user_id": USER["id"], "status": "pending"},
                                    {"id": "guest", "event_id": id, "user_id": "craft-guest", "status": "declined"}] if invited else []}

async def handle(request):
    path = request.path.rstrip("/")
    body = await request.json() if request.can_read_body else {}
    result = []
    if path == "/_test/reset": reset(); result = {"ok": True}
    elif path == "/_test/mode": STATE.update(body); result = {"ok": True}
    elif path == "/_test/state": result = {**STATE, "events": EVENTS}
    elif path in ("", "/health"): result = {"status": True}
    elif path == "/api/config": result = {"status": True, "version": "0.0.0-fixture", "features": {"auth": True, "enable_login_form": True, "enable_websocket": False, "enable_channels": False}, "default_models": [MODEL["id"]]}
    elif path == "/api/version": result = {"version": "0.0.0-fixture"}
    elif path == "/api/v1/auths": result = USER
    elif path == "/api/v1/auths/signin": result = {**USER, "token": "synthetic-token", "token_type": "Bearer"}
    elif path in ("/api/models", "/api/models/base"): result = {"data": [MODEL]}
    elif path == "/api/v1/users/user/settings": result = {"ui": {"models": [MODEL["id"]]}}
    elif path == "/api/v1/calendars": result = [CALENDAR]
    elif path == "/api/v1/calendars/events":
        result = copy.deepcopy(list(EVENTS.values()))
        result[0]["instance_id"] = "paper-series:synthetic-occurrence"
    elif path.startswith("/api/v1/calendars/events/"):
        if request.headers.get("Authorization") != "Bearer synthetic-token":
            return web.json_response({"detail": "Fixture authorization required."}, status=401)
        STATE["writes"].append({"path": path, "method": request.method, "body": body})
        await asyncio.sleep(STATE["delay"])
        if STATE["fail"]: return web.json_response({"detail": "Synthetic unavailable response."}, status=503)
        if STATE["malformed"]: return web.json_response({"status": False})
        if path != "/api/v1/calendars/events/paper-series/rsvp" or request.method != "POST":
            return web.json_response({"detail": "Use the series RSVP endpoint."}, status=404)
        if set(body) != {"status"} or body["status"] not in ("accepted", "tentative", "declined", "pending"):
            return web.json_response({"detail": "Invalid RSVP."}, status=400)
        EVENTS["paper-series"]["attendees"][0]["status"] = body["status"]
        result = {"status": True, "rsvp": body["status"]}
    elif request.method != "GET": result = {"status": True}
    return web.json_response(result)

reset()
app = web.Application()
app.router.add_route("*", "/{path:.*}", handle)
if __name__ == "__main__": web.run_app(app, host="127.0.0.1", port=18191, access_log=None)
