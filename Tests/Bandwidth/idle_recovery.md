# Idle-stream recovery regression

Requires macOS with the Swift compiler and Python 3. From the repository root:

```sh
python3 Tests/Bandwidth/idle_recovery.py --output /path/to/build-output
```

The harness compiles the production recovery body, completion predicate and
socket-update callback. It awaits the recovery Task's body directly so request
counts are deterministic; API, socket, logging and UI boundaries are synthetic
stubs. Checks cover active delivery, silent/disconnected streams, completed
responses, pending tools/questions, fetch errors, stale stream callbacks and
resumption of polling after delivery stops. Socket content remains intact.

To reproduce the failure on an earlier revision, add `--ref <revision>`.
Only invented content and IDs are used. Generated sources, compiler caches and
binaries stay in the requested output directory. This is a native logic
regression, separate from an iOS UI or physical-network test.
