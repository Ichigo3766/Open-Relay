# Entry sync regression

Run `python3 Tests/EntrySync/run.py` from the repository root on macOS with Xcode command-line tools.

The runner compiles the production `syncOnEntry()` method and the `syncWithServer()` guards through the fetch/success timestamp with a synthetic fetch counter. It excludes message reconciliation and uses a deterministic task queue; no app, server, or conversation data are needed. Checks cover a recent successful sync, stale entry, duplicate appearances, initial load, streaming, and retry after failure. Timestamps are set directly, so the test does not sleep through debounce intervals.
