Run on macOS with Xcode command-line tools, using a build directory outside the checkout:

```sh
python3 Tests/ConnectionRecovery/run-tests.py /path/to/test-output
```

The tests compile the production socket and monitor against invented transports. They exercise missing/renewed heartbeats for WebSocket and polling, background and voice-call behavior, stale timers and transport callbacks, request signals, probe coalescing, late results, and server/account replacement. The idle poll is accelerated; external connectivity probes use an in-process URL protocol and never contact the internet.

For the failing control, add `--source-root /path/to/upstream-checkout`. Native demo media uses an invented server that advertises a 1.5-second ping interval and 2-second timeout, then silently drops traffic on the existing socket while accepting new connections.
