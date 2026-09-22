import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import mock_server


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), mock_server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_chat_uses_only_fixture_content(self):
        with urlopen(self.url + "/api/v1/chats/" + mock_server.base.CHAT_ID) as response:
            chat = json.load(response)
        self.assertEqual(chat["title"], "Paper lantern workshop")
        self.assertEqual(len(chat["chat"]["history"]["messages"]), 2)
        self.assertEqual(chat["chat"]["history"]["messages"]["answer"]["content"],
                         "Make a paper lantern with a blue handle and yellow stars.")

    def test_chat_and_configuration_writes_are_rejected(self):
        for path in ("/api/chat/completions", "/api/v1/chats/new", "/api/v1/users/user/settings/update"):
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + path, data=b"{}", headers={"Content-Type": "application/json"}))
            self.assertEqual(error.exception.code, 405)
            error.exception.close()

    def test_sign_in_returns_only_invented_credentials(self):
        with urlopen(Request(self.url + "/api/v1/auths/signin", data=b"{}")) as response:
            result = json.load(response)
        self.assertEqual(result["email"], "demo@example.test")
        self.assertEqual(result["token"], "synthetic-token")


if __name__ == "__main__":
    unittest.main()
