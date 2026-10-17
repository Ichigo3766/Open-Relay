"""Invented loopback-only UI fixture. No files, stored credentials or real service are read."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import base64
import hashlib
import re
import struct
import threading
import time
from urllib.parse import urlsplit

CONTROL = {'fail_save': False}
MODEL = 'aster-model'
USER = {'id': 'invented-observatory-user', 'name': 'Paper Observatory', 'email': 'aster@example.test', 'role': 'user'}
CID = 'af55b47a-ed1d-54f7-95e3-975d9afdfb57'
MESSAGES = [
    {'id': 'demo-question', 'role': 'user', 'content': 'Invent a clockwork planet.', 'models': [MODEL], 'parentId': None, 'childrenIds': ['demo-answer'], 'timestamp': 1700000000},
    {'id': 'demo-answer', 'role': 'assistant', 'content': 'A fictional brass clock follows a paper planet. This is an invented interface demonstration.', 'model': MODEL, 'parentId': 'demo-question', 'childrenIds': [], 'done': True, 'timestamp': 1700000001},
]
CHAT = {'id': CID, 'title': 'Paper Observatory', 'user_id': USER['id'], 'created_at': 1700000000, 'updated_at': 1700000001, 'pinned': False, 'archived': False,
        'chat': {'id': CID, 'title': 'Paper Observatory', 'models': [MODEL], 'params': {}, 'messages': MESSAGES,
                 'history': {'messages': {m['id']: m for m in MESSAGES}, 'currentId': 'demo-answer'}}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def socket(self):
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True
        lock, closed = threading.Lock(), threading.Event()

        def send(text):
            data = text.encode()
            header = bytes([129, len(data)]) if len(data) < 126 else bytes([129, 126]) + struct.pack('!H', len(data))
            with lock:
                self.wfile.write(header + data)
                self.wfile.flush()

        def ping():
            while not closed.wait(1):
                try:
                    send('2')
                except OSError:
                    return

        send('0' + json.dumps({'sid': 'invented-status-socket', 'upgrades': [], 'pingInterval': 1500, 'pingTimeout': 2000, 'maxPayload': 1000000}))
        threading.Thread(target=ping, daemon=True).start()
        try:
            while True:
                head = self.rfile.read(2)
                if len(head) != 2 or head[0] & 15 == 8:
                    return
                size = head[1] & 127
                if size == 126:
                    size = struct.unpack('!H', self.rfile.read(2))[0]
                elif size == 127:
                    size = struct.unpack('!Q', self.rfile.read(8))[0]
                if size > 1000000:
                    return
                mask = self.rfile.read(4) if head[1] & 128 else None
                data = self.rfile.read(size)
                if mask:
                    data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
                text = data.decode() if head[0] & 15 == 1 else ''
                if text.startswith('40'):
                    send('40{"sid":"invented-status-socket"}')
                elif text.startswith('42'):
                    match = re.match(r'42(\d+)\[', text)
                    if match:
                        send('43' + match[1] + '[true]')
        except (OSError, ValueError, struct.error):
            pass
        finally:
            closed.set()

    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            return self.socket()
        path = urlsplit(self.path).path.rstrip('/')
        if path in ('', '/health'):
            return self.reply({'status': True})
        if path == '/api/config':
            return self.reply({'status': True, 'version': '0.12.0', 'name': 'Paper Observatory', 'features': {'auth': True, 'enable_login_form': True, 'enable_signup': False, 'enable_websocket': True}, 'default_models': [MODEL]})
        if path == '/api/v1/auths':
            return self.reply(USER)
        if path == '/api/models':
            return self.reply({'data': [{'id': MODEL, 'name': 'Paper Model', 'owned_by': 'openai'}]})
        if path == '/api/v1/models/model':
            return self.reply({'id': MODEL, 'name': 'Paper Model', 'meta': {}, 'params': {}})
        if path == '/api/v1/users/user/settings':
            return self.reply({'ui': {'models': [MODEL]}})
        if path == '/api/v1/chats':
            return self.reply([] if 'page=2' in self.path else [{k: v for k, v in CHAT.items() if k != 'chat'}])
        if path == '/api/v1/chats/' + CID:
            return self.reply(CHAT)
        if path in ('/api/version', '/api/version/updates'):
            return self.reply({'version': '0.12.0', 'current': '0.12.0', 'latest': '0.12.0'})
        if path == '/audit/app-update':
            return self.reply({'resultCount': 1, 'results': [{'version': '0.0.0'}]})
        if path == '/favicon.ico' or path.startswith('/ws/'):
            return self.reply({}, 404)
        return self.reply([])

    def do_POST(self):
        size = int(self.headers.get('Content-Length', 0))
        value = json.loads(self.rfile.read(size)) if size else {}
        path = urlsplit(self.path).path.rstrip('/')
        if path == '/audit/control':
            CONTROL.update(value)
            return self.reply(CONTROL)
        if path == '/api/v1/auths/signin':
            return self.reply({**USER, 'token': 'invented-ui-fixture-token', 'token_type': 'Bearer'})
        if path == '/api/v1/chats/' + CID:
            return self.reply({'detail': 'Invented save failure'}, 503) if CONTROL['fail_save'] else self.reply(CHAT)
        return self.reply({})


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18365), Handler).serve_forever()
