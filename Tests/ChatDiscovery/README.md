# Chat discovery checks

Run with Python 3 and the Xcode Swift 6 toolchain on macOS:

```sh
python3 Tests/ChatDiscovery/run-tests.py /path/to/external-test-output
```

The output directory must be outside the checkout. The runners extract the actual production request methods, GET actor, and model-discovery method, then compile them against freshly invented transports. They do not connect to a server or read app data.

The 97 request checks cover concurrent GET sharing, request/header/authentication separation, timeout and cache-policy separation, independent mutations, failure cleanup, cancellation, retries, and fresh GETs after a write, including a GET started while that write was pending or its acknowledgment was lost. The 10 model checks cover parallel discovery, server-default selection, existing selection, fallback, cache population, and prompt completion when models fail while the default request is slow.

For an earlier revision, pass `--source-root /path/to/earlier-checkout`. Identical delayed requests provide a small component latency measurement; native performance results are reported in the pull request.
