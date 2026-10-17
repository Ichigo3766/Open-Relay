# Connection status checks

The focused checks compile the actual `ServerConnectionMonitor` with invented network/path/socket implementations. They do not connect to a server, use stored credentials, or change the production polling intervals, backoff or failure threshold.

On macOS with Xcode command-line tools:

```sh
python3 Tests/ConnectionStatus/run-tests.py /path/outside/checkout/status-checks
```

Use `--source-root /path/to/control-checkout` to run the same assertions against a control revision. The old UI intentionally fails assertions about initial uncertainty, consistent labels and foreground recovery.

`StatusUITests.swift` exercises the full app on a disposable simulator using an invented loopback service and a private display-state fixture. The fixture injects connection states and a multiline draft into the existing production views; it does not simulate packet loss. The monitor checks above independently exercise the real health-result transitions. Native checks cover saved/empty-cache presentation, offline and server errors, initial connection and recovery, sidebar status, retry, and portrait/landscape composer overlap. Screenshots are XCTest attachments.

For a full native run, start `fixture-server.py`, apply `prepare-display-fixture.py /path/to/disposable-checkout`, build/install that checkout and add `StatusUITests.swift` to a native UI test target. Use an empty disposable simulator. The fake sign-in and all content are invented; no existing account or server is needed. The helper also routes automatic app-version lookups to loopback in this test build. Do not distribute the instrumented build.

The native fixture is a test-build-only `.onAppear` hook in `ChatDetailView` that reads `SYNTHETIC_STATUS_FIXTURE`. It supplies `connected`, `checking`, `reconnecting`, `offline`, `server` or `blocking` to the shared monitor. The control also supplies its existing cached-content/overlay flags. `draft` supplies twelve freshly invented lines. The native send test then makes the invented history-save endpoint return HTTP 503 and checks the resulting production error notice. No fixture hook or synthetic conversation is part of the production change.

The draft regression checks the visible error text and editable text view rectangles for intersection with the keyboard closed and open, and checks that the notice remains adjacent to the input. Error dismissal must retain the text. The production notice is placed outside the edit/normal/read-only composer branches, so the same layout owner handles all three.
