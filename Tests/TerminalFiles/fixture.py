"""Isolated loopback fixture. Every chat, file and credential here is synthetic."""
import argparse
import asyncio
import json
from pathlib import Path

from aiohttp import web
import socketio

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai"}
TOKEN = "synthetic-token"
CHAT = "synthetic-files"


def reference(name, mime):
    return {"source": "open_terminal", "type": "file", "exists": True,
            "terminal_selector": "demo-terminal", "terminal_id": "demo-terminal",
            "session_id": CHAT, "path": "/workspace/" + name, "name": name, "mime_type": mime}


def make_chat(identifier, title, files):
    output = []
    for index, (name, mime) in enumerate(files):
        call = "file-" + str(index)
        ref = reference(name, mime)
        ref["session_id"] = identifier
        if name == "motion.mp4": ref["size"] = 52_500_000
        output += [{"type": "function_call", "id": call, "call_id": call,
                    "name": "display_file", "arguments": json.dumps({"path": ref["path"], "inline": True}), "status": "completed"},
                   {"type": "function_call_output", "call_id": call,
                    "output": [{"type": "input_text", "text": json.dumps(ref)}]}]
    output += [{"type": "message", "content": [{"type": "output_text", "text": "The demonstration files are ready. Choose one to open or save."}]}]
    question = {"id": "question", "parentId": None, "childrenIds": ["answer"], "role": "user",
                "content": "Show the sample files.", "timestamp": 1700000000}
    answer = {"id": "answer", "parentId": "question", "childrenIds": [], "role": "assistant", "model": MODEL["id"],
              "content": "", "output": output, "done": True, "timestamp": 1700000001}
    chat = {"id": identifier, "title": title, "models": [MODEL["id"]],
            "history": {"currentId": "answer", "messages": {"question": question, "answer": answer}},
            "messages": [question, answer]}
    return {"id": identifier, "title": title, "user_id": USER["id"], "chat": chat,
            "created_at": 1700000000, "updated_at": 1700000000, "archived": False, "pinned": False}


CHATS = {
    CHAT: make_chat(CHAT, "Sample attachments", [("motion.mp4", "video/mp4"), ("tone.m4a", "audio/mp4"),
                                                ("notes.txt", "text/plain"), ("sample.png", "image/png")]),
    "synthetic-errors": make_chat("synthetic-errors", "Recovery examples", [("missing.mp4", "video/mp4"),
        ("disconnected.mp4", "video/mp4"), ("slow.mp4", "video/mp4"), ("retry.mp4", "video/mp4")]),
    "synthetic-live": make_chat("synthetic-live", "Live display event", []),
    "synthetic-active": make_chat("synthetic-active", "Originating terminal request", []),
}
ordinary = make_chat("synthetic-ordinary", "Ordinary rich content", [])
ordinary["chat"]["messages"][1]["output"] = [
    {"type": "function_call", "call_id": "table", "name": "sample_table", "arguments": "{}", "status": "completed"},
    {"type": "function_call_output", "call_id": "table", "output": [{"type": "input_text", "text": "Two rows returned."}],
     "embeds": ["<!doctype html><html><body style='font:18px system-ui;padding:16px'><h2>Sample table</h2><p>North: 12<br>South: 18</p></body></html>"]},
    {"type": "message", "content": [{"type": "output_text", "text": "An ordinary image and a **formatted** response.\n\n![Blue sample](/api/v1/files/demo-image/content)"}]},
]
CHATS["synthetic-ordinary"] = ordinary


def application(folder):
    app = web.Application()
    sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
    sio.attach(app, socketio_path="ws/socket.io")
    stats = {"requests": {}, "bytes": {}, "rejected": 0}
    active_request = {}

    @sio.on("user-join")
    async def join(sid, data):
        return {"id": USER["id"]}

    async def handle(request):
        path = request.path.rstrip("/")
        if path == "/fixture/reset":
            stats.update(requests={}, bytes={}, rejected=0)
            CHATS["synthetic-live"] = make_chat("synthetic-live", "Live display event", [])
            active_request.clear()
            return web.json_response(stats)
        if path == "/fixture/metrics": return web.json_response(stats)
        if path == "/fixture/enable-terminal":
            MODEL["meta"] = {"capabilities": {"terminal": True}}
            MODEL["info"] = {"meta": MODEL["meta"]}
            return web.json_response({"enabled": True})
        if path == "/fixture/active-request": return web.json_response(active_request)
        if path == "/api/chat/completions":
            body = await request.json()
            active_request.update(chat_id=body.get("chat_id"), terminal_id=body.get("terminal_id"))

            async def display():
                await asyncio.sleep(0.4)
                await sio.emit("chat-events", {"chat_id": body.get("chat_id"), "message_id": body.get("id"),
                    "session_id": body.get("session_id"), "data": {"type": "terminal:display_file", "data": {"path": "/workspace/notes.txt"}}})

            sio.start_background_task(display)
            return web.json_response({"status": True, "task_id": "fixture-task"})
        if path == "/fixture/live":
            await sio.emit("chat-events", {"chat_id": "synthetic-live", "message_id": "answer", "data": {
                "type": "terminal:display_file", "data": {**reference("notes.txt", "text/plain"), "session_id": "synthetic-live"}}})
            return web.json_response({"sent": True})
        if path == "/fixture/live-saved":
            CHATS["synthetic-live"] = make_chat("synthetic-live", "Live display event", [("notes.txt", "text/plain")])
            await sio.emit("chat-events", {"chat_id": "synthetic-live", "message_id": "answer", "data": {
                "type": "chat:completion", "data": {"done": True, "output": CHATS["synthetic-live"]["chat"]["messages"][1]["output"]}}})
            return web.json_response({"saved": True})
        if path == "/api/v1/terminals/demo-terminal/files/view":
            name = Path(request.query.get("path", "")).name
            stats["requests"][name] = stats["requests"].get(name, 0) + 1
            if request.headers.get("Authorization") != "Bearer " + TOKEN or request.headers.get("X-Session-Id") not in CHATS:
                stats["rejected"] += 1
                return web.Response(status=403)
            statuses = {"missing.mp4": 404, "disconnected.mp4": 503, "denied.mp4": 403}
            if name in statuses: return web.Response(status=statuses[name])
            if name == "redirect.mp4": return web.Response(status=302, headers={"Location": "/fixture/redirect-target"})
            if name == "retry.mp4" and stats["requests"][name] == 1: return web.Response(status=500)
            source = folder / ("motion.mp4" if name in ("slow.mp4", "retry.mp4", "oversized.mp4") else name)
            if not source.is_file(): return web.Response(status=404)
            mime = {".mp4": "video/mp4", ".m4a": "audio/mp4", ".txt": "text/plain", ".png": "image/png"}.get(source.suffix, "application/octet-stream")
            length = 300 * 1024 * 1024 if name == "oversized.mp4" else source.stat().st_size
            # The native proxy strips Content-Length. Exercise chunked downloads
            # by default, and the declared-size guard in the oversized case.
            headers = {"Content-Type": mime}
            if name == "oversized.mp4": headers["Content-Length"] = str(length)
            response = web.StreamResponse(headers=headers)
            await response.prepare(request)
            try:
                with source.open("rb") as stream:
                    while chunk := stream.read(64 * 1024):
                        await response.write(chunk)
                        stats["bytes"][name] = stats["bytes"].get(name, 0) + len(chunk)
                        await asyncio.sleep(0.08 if name == "slow.mp4" else 0.003)
                await response.write_eof()
            except (ConnectionError, asyncio.CancelledError): pass
            return response
        if path == "/fixture/redirect-target":
            stats["requests"]["redirect-target"] = stats["requests"].get("redirect-target", 0) + 1
            return web.Response(text="Redirect should not be followed")
        if path == "/api/v1/files/demo-image/content": return web.FileResponse(folder / "sample.png")
        result = []
        if path in ("", "/health"): result = {"status": True}
        elif path == "/api/config":
            result = {"status": True, "version": "0.0.0-fixture", "name": "File Demo", "features": {
                "auth": True, "enable_login_form": True, "enable_signup": False, "enable_websocket": True}, "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path == "/api/v1/auths/signin": result = {**USER, "token": TOKEN, "token_type": "Bearer"}
        elif path == "/api/models": result = {"data": [MODEL]}
        elif path.startswith("/api/v1/models/model"): result = MODEL
        elif path == "/api/v1/users/user/settings": result = {"ui": {}}
        elif path in ("/api/v1/chats", "/api/v1/chats/list"):
            result = [{k: v for k, v in chat.items() if k != "chat"} for chat in CHATS.values()] if request.query.get("page", "1") == "1" else []
        elif path.startswith("/api/v1/chats/"): result = CHATS.get(path.split("/")[4], [])
        elif path == "/api/v1/terminals": result = [{"id": "demo-terminal", "name": "Demo Terminal"}]
        return web.json_response(result)

    app.router.add_route("*", "/{path:.*}", handle)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18191)
    args = parser.parse_args()
    web.run_app(application(args.files), host="127.0.0.1", port=args.port, access_log=None)
