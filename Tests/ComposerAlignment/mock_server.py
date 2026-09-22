"""Invented, read-only composer fixture. No real account or server is accessed."""
import argparse
import importlib.util
from http.server import ThreadingHTTPServer
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "composer_fixture_base", Path(__file__).parent.parent / "ReadAloudPlayer/mock_server.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
base.CHAT["title"] = base.CHAT["chat"]["title"] = "Paper lantern workshop"
base.MESSAGES["question"]["content"] = "Suggest an imaginary craft project."
base.MESSAGES["answer"]["content"] = "Make a paper lantern with a blue handle and yellow stars."

class Handler(base.Handler):
    def do_POST(self):
        if self.path == "/api/v1/auths/signin" or self.path.endswith("/read"):
            return super().do_POST()
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send({"detail": "This fixture does not accept messages or configuration writes."}, 405)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18087)
    args = parser.parse_args()
    print(f"Synthetic composer fixture: http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
