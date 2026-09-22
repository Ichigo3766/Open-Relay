# Reconnect refresh regression

Run `python3 Tests/ReconnectRefresh/run.py` from the repository root on macOS with Xcode command-line tools.

The runner compiles the production phone/tablet registration methods and Socket.IO connect callback dispatch with synthetic counters. Task closures are drained deterministically; no app, server, credentials, or conversation data are used. Checks cover initial connection, repeated reconnects, duplicate registration, streaming, and no active chat. Each list should refresh once per connection, while reconnect-only config and active-chat work remains intact.
