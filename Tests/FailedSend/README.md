# Failed-send regression checks

Run on macOS with Python 3 and Swift installed:

```sh
python3 Tests/FailedSend/run.py --output /path/to/disposable/build-output
```

The runner extracts complete production send, history-sync, reconciliation,
load/reload and stream-cleanup methods with the original message/history models.
It compares public v6.2 (`84ea58b4e05b967fde923ac09206f17668777450`) with
the current working tree. The clone is never modified by the runner. Generated
source, executable, temporary files and module caches use the requested output
directory.

Synthetic API boundaries fail history saving before changing mock server state,
using connection-loss, timeout and offline errors. Socket, upload, notification,
configuration and UI-specific dependencies are inert stubs; defaults are kept
only in memory. The runner uses no real server, account or chat.

The baseline reproduces the loss and must fail the draft-retention contract.
The current implementation must pass that contract, including existing/new
chats, socket/fallback paths, newer typing, queued messages without automatic
resending, original audio attachments, changed session/conversation and newer
stream guards, explicit retry, temporary chats and accepted-history controls.
The runner returns success only when these expectations all hold.

These are focused native Swift logic tests, not an iOS UI or physical-network
test. They do not cover a durable outbox or process termination during sending.
