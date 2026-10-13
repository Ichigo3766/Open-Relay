The checks compile the production completion predicate and deserialize freshly invented JSON, matching `ConversationCache.Response`. They cover finished, unfinished, missing, malformed and mixed history/flat representations. An invalid sibling must not hide an unfinished message.

Run on macOS with Swift and Python. Benchmarks use optimized builds with whole-module optimization. Keep generated files outside the checkout:

```sh
python3 Tests/CacheMessageCompletion/run-tests.py "$TEST_OUTPUT/checks"
python3 Tests/CacheMessageCompletion/generate-fixture.py "$TEST_OUTPUT/chat.json"
python3 Tests/CacheMessageCompletion/run-tests.py "$TEST_OUTPUT/benchmark" --benchmark "$TEST_OUTPUT/chat.json"
python3 Tests/CacheMessageCompletion/run-tests.py "$TEST_OUTPUT/control" --source /path/to/control/ConversationCache.swift --benchmark "$TEST_OUTPUT/chat.json"
```

Set `TEST_OUTPUT` to a writable external test directory first. The generator writes 100,000 completed messages in both history and flat representations. Timing excludes file I/O and JSON deserialization, measures three checks per fresh process, and reports per-check CPU/wall time. Peak RSS covers the entire benchmark process. Alternate fresh control/candidate processes when comparing results. No server connection or instance data is used.
