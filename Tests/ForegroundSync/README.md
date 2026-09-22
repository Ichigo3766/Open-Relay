# Foreground sync regression

Run `python3 Tests/ForegroundSync/run.py` from the repository root on macOS with Xcode command-line tools.

The runner compiles the production foreground/background observer registration and view visibility updates with synthetic dependencies. An in-memory notification center and deterministic task queue exercise five cached chats without an app, server, or user data. Checks cover visible/hidden chats, multiple views sharing a model, repeated appearance/disappearance, short and unknown background durations, repeated registration, background stream monitoring, and paused transcription recovery. This isolates callback decisions; it is not a SwiftUI lifecycle or network integration test.
