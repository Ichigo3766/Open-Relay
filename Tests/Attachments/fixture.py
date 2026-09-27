"""Disposable loopback API. All accounts, chats, documents, and settings are invented."""
import argparse
import asyncio
import copy
import fnmatch
import uuid

from aiohttp import web
import socketio

USER = {"id": "fixture-user", "name": "Demo", "email": "demo@example.test", "role": "user"}
MODEL = {"id": "fixture-model", "name": "Demo Model", "owned_by": "openai",
         "info": {"meta": {"capabilities": {"file_context": True, "builtin_tools": True}}}}
TOKEN = "synthetic-token"


def document(index):
    name = "Orchard guide.txt" if index == 27 else f"Sample document {index:02}.txt"
    return {"id": f"document-{index}", "filename": name, "created_at": 1700000000 + index,
            "updated_at": 1700000000 + index, "user_id": USER["id"],
            "meta": {"name": name, "content_type": "text/plain", "size": 42},
            "data": {"status": "completed"}, "content_type": "text/plain", "size": 42}


DOCUMENTS = [document(i) for i in range(1, 28)]
COLLECTIONS = [{"id": f"collection-{i}", "name": f"Sample collection {i:02}",
                "description": "Invented demonstration documents", "files": [DOCUMENTS[0]],
                "created_at": 1700000000, "updated_at": 1700000000} for i in range(1, 24)]
FOLDERS = [{"id": "sample-folder", "name": "Sample folder", "items": [], "meta": {}}]


def file_ref():
    file = document(1)
    return {"type": "file", "id": file["id"], "url": file["id"], "name": file["filename"],
            "content_type": "text/plain", "context": "full", "size": 42,
            "collection_name": "file-document-1", "file": file}


def make_chat(identifier, title):
    question = {"id": "question", "parentId": None, "childrenIds": ["answer"], "role": "user",
                "content": "Please summarize this demonstration document.", "files": [file_ref()],
                "timestamp": 1700000000, "models": [MODEL["id"]]}
    answer = {"id": "answer", "parentId": "question", "childrenIds": [], "role": "assistant",
              "content": "The sample document describes three fictional garden layouts.",
              "model": MODEL["id"], "done": True, "timestamp": 1700000001}
    chat = {"title": title, "models": [MODEL["id"]], "files": [file_ref()],
            "history": {"currentId": "answer", "messages": {"question": question, "answer": answer}},
            "messages": [question, answer]}
    return {"id": identifier, "title": title, "chat": chat, "user_id": USER["id"],
            "created_at": 1700000000, "updated_at": 1700000000, "archived": False, "pinned": False}


def application():
    app = web.Application()
    sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=[])
    sio.attach(app, socketio_path="ws/socket.io")
    chats, requests = {}, []
    settings = {"ui": {"defaultUploadContext": "full", "fixtureUnrelatedSetting": "keep"}}

    def reset():
        chats.clear()
        chats.update({identifier: make_chat(identifier, title) for identifier, title in [
            ("synthetic-context", "Attachment context"), ("synthetic-removal", "Remove a source")]})
        requests.clear()
    reset()

    @sio.on("user-join")
    async def join(sid, data):
        return {"id": USER["id"]}

    async def handle(request):
        path = request.path.rstrip("/")
        if path == "/fixture/reset":
            reset()
            return web.json_response({"reset": True})
        if path == "/fixture/state":
            return web.json_response({"requests": requests, "chats": chats, "settings": settings})
        if path == "/fixture/remove":
            chats["synthetic-removal"]["chat"]["files"] = []
            return web.json_response({"removed": True})
        if path == "/fixture/recording":
            # UI tests can signal recording boundaries without touching app code.
            app["recording"] = request.query.get("state", "")
            return web.json_response({"state": app["recording"]})
        if path == "/fixture/recording-state":
            return web.json_response({"state": app.get("recording", "")})
        body = await request.json() if request.can_read_body and request.content_type == "application/json" else {}
        if path.startswith("/api/v1/") and path not in ("/api/v1/auths/signin",):
            if request.headers.get("Authorization") != "Bearer " + TOKEN:
                return web.json_response({"detail": "Synthetic authentication required"}, status=401)
        if path == "/api/chat/completions":
            requests.append({"path": path, "body": body})
            identifier = body["chat_id"]
            chat = chats.setdefault(identifier, make_chat(identifier, "Attachment context"))["chat"]
            history = chat["history"]
            user = body.get("user_message")
            if user: history["messages"][user["id"]] = copy.deepcopy(user)
            refs = body.get("files") or []
            result = "No attachment context was sent." if not refs else "Context received:\n\n" + "\n\n".join(
                f"{f.get('name', f.get('id', 'File'))} — {'Entire Document' if f.get('context') == 'full' else 'Focused Retrieval'}"
                for f in refs)
            answer = {"id": body["id"], "role": "assistant", "parentId": body.get("parent_id"),
                      "childrenIds": [], "content": result, "model": MODEL["id"], "done": True,
                      "timestamp": 1700000010}
            history["messages"][answer["id"]] = answer
            history["currentId"] = answer["id"]

            async def finish():
                await asyncio.sleep(0.6)
                await sio.emit("chat-events", {"chat_id": identifier, "message_id": answer["id"],
                    "session_id": body.get("session_id"), "data": {"type": "chat:completion", "data": {
                        "content": result, "done": True}}})
            sio.start_background_task(finish)
            return web.json_response({"status": True, "task_id": "fixture-task"})
        if path == "/api/chat/completed": return web.json_response({"status": True})
        if path == "/api/v1/chats/new":
            identifier = "created-" + str(uuid.uuid4())
            chat = make_chat(identifier, body.get("chat", {}).get("title", "Sample chat"))
            chat["chat"] = body.get("chat", {})
            chats[identifier] = chat
            return web.json_response(chat)
        if path.startswith("/api/v1/chats/") and path.split("/")[4] in chats:
            chat = chats[path.split("/")[4]]
            if request.method == "POST" and "chat" in body:
                requests.append({"path": path, "body": body})
                chat["chat"].update(body["chat"])
            return web.json_response(chat)
        if path == "/api/v1/files/search":
            query = request.query.get("filename", "*")
            skip, limit = int(request.query.get("skip", 0)), int(request.query.get("limit", 50))
            requests.append({"path": path, "query": dict(request.query)})
            matches = [f for f in DOCUMENTS if fnmatch.fnmatchcase(f["filename"].lower(), query.lower())]
            return web.json_response(matches[skip:skip + limit])
        if path == "/api/v1/files": return web.json_response({"items": DOCUMENTS[:3], "total": len(DOCUMENTS)})
        if path.startswith("/api/v1/files/"):
            file = next((f for f in DOCUMENTS if f["id"] == path.split("/")[4]), None)
            if not file: return web.Response(status=404)
            if path.endswith("/data/content"): return web.json_response({"content": "Freshly invented sample text."})
            return web.json_response(file)
        if path == "/api/v1/knowledge": return web.json_response(COLLECTIONS[:3])
        if path.startswith("/api/v1/knowledge/"):
            query = request.query.get("query", "").lower()
            page = int(request.query.get("page", 1))
            items = DOCUMENTS if path.endswith("/files") else COLLECTIONS
            items = [f for f in items if query in f.get("name", f.get("filename", "")).lower()]
            requests.append({"path": path, "query": dict(request.query)})
            return web.json_response({"items": items[(page - 1) * 5:page * 5], "total": len(items)})
        result = []
        if path in ("", "/health"): result = {"status": True}
        elif path == "/api/config": result = {"status": True, "version": "0.0.0-fixture", "name": "Attachment Demo",
            "features": {"auth": True, "enable_login_form": True, "enable_signup": False, "enable_websocket": True},
            "default_models": [MODEL["id"]]}
        elif path == "/api/version": result = {"version": "0.0.0-fixture"}
        elif path == "/api/v1/auths": result = USER
        elif path == "/api/v1/auths/signin": result = {**USER, "token": TOKEN, "token_type": "Bearer"}
        elif path == "/api/models": result = {"data": [MODEL]}
        elif path.startswith("/api/v1/models/model"): result = {**MODEL, "meta": MODEL["info"]["meta"]}
        elif path == "/api/v1/users/user/settings": result = settings
        elif path == "/api/v1/users/user/settings/update":
            settings.update(body)
            result = settings
        elif path in ("/api/v1/chats", "/api/v1/chats/list"):
            result = [{k: v for k, v in c.items() if k != "chat"} for c in chats.values()] if request.query.get("page", "1") == "1" else []
        elif path == "/api/v1/folders": result = FOLDERS
        return web.json_response(result)

    app.router.add_route("*", "/{path:.*}", handle)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18191)
    args = parser.parse_args()
    web.run_app(application(), host="127.0.0.1", port=args.port, access_log=None)
