import json
import threading
import unittest
from urllib.request import urlopen

from rendering_server import CHATS, Handler, ThreadingHTTPServer


class RenderingFixtures(unittest.TestCase):
    def test_complete_message_chains(self):
        self.assertEqual(len({chat["id"] for chat in CHATS}), len(CHATS))
        message_ids = [message["id"] for chat in CHATS for message in chat["chat"]["messages"]]
        self.assertEqual(len(message_ids), len(set(message_ids)))
        for chat in CHATS:
            history = chat["chat"]["history"]
            messages = history["messages"]
            current = history["currentId"]
            visited = set()
            while current is not None:
                self.assertNotIn(current, visited)
                visited.add(current)
                message = messages[current]
                parent = message["parentId"]
                if parent is not None:
                    self.assertIn(current, messages[parent]["childrenIds"])
                    self.assertTrue(message["done"])
                current = parent
            self.assertEqual(visited, set(messages))

    def test_history_and_large_reasoning_cases(self):
        self.assertEqual(len(CHATS[3]["chat"]["messages"]), 513)
        self.assertGreater(len(CHATS[2]["chat"]["messages"][-1]["content"]), 100000)
        self.assertGreater(len(CHATS[4]["chat"]["messages"][-1]["content"]), 100000)

    def test_loopback_api(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            for path, expected in [("/api/v1/chats/?page=2", []),
                                   ("/api/v1/chats/" + CHATS[2]["id"], CHATS[2])]:
                with urlopen(base + path) as response:
                    self.assertEqual(json.load(response), expected)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
