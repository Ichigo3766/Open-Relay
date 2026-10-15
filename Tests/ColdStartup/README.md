Run on macOS with Xcode command-line tools, using a build directory outside the checkout:

```sh
python3 Tests/ColdStartup/run-tests.py /path/to/test-output
```

The tests compile production discovery, loading, restoration, and disk-cache methods with fresh invented metadata and transports. They cover cache reuse, pipe model payloads, default selection, offline refresh, account isolation, stale writes, cache controls and budget, avatar invalidation, parallel restoration, refreshed defaults, preserved selections, and settings failures. All cache/build files are disposable; no application account or chat is read.

For the failing control, add `--source-root /path/to/upstream-checkout`. Native tests verify the launch overlay through actual focus/typing. Demo media uses an invented server with eight-second delays on model and user-setting responses, then restarts the app after warming its cache.
