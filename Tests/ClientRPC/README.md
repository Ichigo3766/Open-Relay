# Client-executed RPC errors

Baseline: Open Relay 6.0 (`4151a73`), Open WebUI `8bd8b4f`.

`python3 Tests/ClientRPC/run.py` compiles the actual socket dispatch and routing
methods. Only network output, cache invalidation, registrations, and logging are
stubbed. On the baseline, 29 of 31 checks fail; the two ordinary-event routing
checks already pass. All 31 pass with the fix.

Coverage includes four unsupported execution types, requests for unopened chats,
multiple registered views, no callback, legacy calls without embedded session,
foreign sessions, native Python error fields, and unchanged confirmation and
completion delivery.

For a real transport check, run `fixture.py` with `aiohttp` and `python-socketio`.
Connect only an isolated simulator to `http://127.0.0.1:18191` with the invented
login `demo@example.test` / `synthetic`. POST `/_test/probe` to exercise four
Socket.IO calls for a chat that is not open. Baseline replies time out; fixed
replies contain a descriptive error and `status: false`.

Verified with the Release simulator app on iOS 26.5: all four calls timed out on
the 6.0-based baseline; all four returned the expected error through the real
Socket.IO transport after the fix. The full Release build also passes.

This deliberately does not implement a browser JavaScript/Pyodide runtime or
client-managed provider credentials. Server-managed tools, terminals, and model
requests are unchanged. Unsupported calls no longer pretend to execute or leave
the server waiting for its callback timeout. Generic event callers receive the
same error-object convention used by the server's own timeout handling.

All fixtures are freshly invented. No user data, external providers, arbitrary
execution, or private endpoints are used.
