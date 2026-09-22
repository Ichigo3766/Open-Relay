"""Loopback-only, in-memory rendering fixtures. No real service or stored chats.

Run: python3 Tests/ReasoningRendering/rendering_server.py
Sign in at http://127.0.0.1:18188 with demo@example.test / synthetic.
"""
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ReadAloudPlayer"))
from mock_server import Handler as BaseHandler, USER

PARAGRAPH = (
    "A copper telescope stands beside a blue notebook. Seven paper stars mark the imaginary map. "
    "A quiet observatory records the changing colors of the sky, then stores the numbered sketch for another evening."
)


def paragraphs(count):
    return "\n\n".join(f"**Observation {index:04d}**\n\n{PARAGRAPH}" for index in range(1, count + 1))


def chat(index, title, answers):
    chat_id = f"10000000-0000-4000-8000-{index:012d}"
    def message_id(number):
        return f"20000000-0000-4000-8{index:03d}-{number:012d}"
    question = message_id(0)
    messages = {question: {"id": question, "role": "user", "content": "Describe an imaginary observatory.", "parentId": None, "childrenIds": [message_id(1)], "models": ["fixture"], "timestamp": 1700000000}}
    for number, content in enumerate(answers, 1):
        identifier = message_id(number)
        messages[identifier] = {"id": identifier, "role": "assistant", "content": content,
                                "parentId": message_id(number - 1),
                                "childrenIds": [message_id(number + 1)] if number < len(answers) else [],
                                "model": "fixture", "done": True, "timestamp": 1700000000 + number}
    return {"id": chat_id, "title": title, "user_id": USER["id"], "created_at": 1700000000,
            "updated_at": 1700000000 + index, "pinned": False, "archived": False,
            "chat": {"id": chat_id, "title": title, "models": ["fixture"], "params": {},
                     "history": {"messages": messages, "currentId": message_id(len(answers))},
                     "messages": list(messages.values())}}


def reasoning(text):
    return '<details type="reasoning" done="true"><summary>Thinking</summary>' + text + "</details>\n\n" + paragraphs(3)


CHATS = [
    chat(1, "Short completed answer", [paragraphs(12)]),
    chat(4, "Very large completed answer", [paragraphs(1536)]),
    chat(5, "Large completed reasoning", [reasoning(paragraphs(512))]),
    chat(6, "Many completed messages", [f"**Message {index:04d}**\n\n{PARAGRAPH}" for index in range(1, 513)]),
    chat(7, "Long reasoning paragraph", [reasoning(" ".join([PARAGRAPH] * 512))]),
    chat(8, "Literal reasoning text", [reasoning("**Literal asterisks**\n\n    Indented text\n\n星と月 👨‍👩‍👧‍👦 café\n\nLast line.")]),
]


class Handler(BaseHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path.rstrip("/")
        if path == "/api/v1/chats":
            return self.send([{key: value for key, value in item.items() if key != "chat"} for item in CHATS]
                             if parse_qs(parsed.query).get("page", ["1"])[0] == "1" else [])
        for item in CHATS:
            if path == "/api/v1/chats/" + item["id"]:
                return self.send(item)
        return super().do_GET()


if __name__ == "__main__":
    print("Synthetic rendering fixtures: http://127.0.0.1:18188", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18188), Handler).serve_forever()
