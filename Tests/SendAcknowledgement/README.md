# Send acknowledgment checks

Run with Python 3 and the Xcode Swift 6 toolchain on macOS:

```sh
python3 Tests/SendAcknowledgement/run-tests.py /path/to/external-test-output
```

The output directory must be outside the checkout. Runners compile the actual completion-error handling, loaded-reply resolution, draft-consumption code, and recovery store against invented fixtures. They do not connect to a server or read app data.

The 73 checks cover lost acknowledgment versus terminal HTTP/TLS errors, unfinished replies with no active task, recognized and unrecognized receipts, cancellation/account/session changes, exact draft consumption, preservation of later edits and selections, and durable draft recovery. Disk checks include chat-ID migration, manual deletion, pending audio preservation, and storage failure.

A pending send checkpoints the draft once using the existing recovery store. A valid generation acknowledgment consumes only the unchanged sent draft. Clearing the text removes a recovery entry without a recording; ordinary typing does not create recovery files. There is no new discard-draft interface.

Native synthetic checks additionally exercise delayed and lost acknowledgment, app restart, late answers, new edits, new-chat sending, and a large history. See the pull request for measured results and synthetic media.
