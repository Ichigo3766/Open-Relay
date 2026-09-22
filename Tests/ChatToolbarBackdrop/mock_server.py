"""Invented, in-memory scrolling fixture. Never reads or contacts a real server."""
import importlib.util
from pathlib import Path
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location(
    'toolbar_fixture_base', Path(__file__).parent.parent / 'ReadAloudPlayer/mock_server.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
base.CHAT['title'] = base.CHAT['chat']['title'] = 'Paper kite notebook'
base.MESSAGES['question']['content'] = 'Write an imaginary notebook about paper kites.'
base.MESSAGES['answer']['content'] = '\n\n'.join(
    f'**Notebook entry {i:02d}**\n\n'
    'A paper kite floats over the little garden. Blue ribbons turn in the breeze, '
    'while yellow flowers brighten the path. The notebook records a quiet afternoon '
    'with lanterns, clouds, and a painted wooden gate.'
    for i in range(1, 37))

if __name__ == '__main__':
    print('Synthetic toolbar fixture: http://127.0.0.1:18088', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 18088), base.Handler).serve_forever()
