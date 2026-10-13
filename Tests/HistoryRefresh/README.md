# History refresh regression checks

On macOS with Swift 6:

```sh
python3 Tests/HistoryRefresh/run-tests.py /path/to/external-storage/history-checks
```

The production load, metadata refresh and server adoption methods and five production model files are compiled unchanged. A small observable owner counts conversation assignments; networking, logging, control discovery and unused image extraction are stubbed. Inputs are freshly invented. Generated binaries and module caches remain outside the checkout.

Checks cover incomplete and cyclic parent chains, inactive branches, missing nodes, longer flat lists, selected models, offline and deferred loading, context usage and checkpoint replacement/clearing, unrelated conversation IDs, live-stream ownership, background replies and bounded observable history assignments.

For an optimized component benchmark:

```sh
python3 Tests/HistoryRefresh/run-tests.py --benchmark 100000 load /path/to/external-storage/history-benchmark
/path/to/external-storage/history-benchmark/checks --benchmark 100000 metadata
```

Other modes are `adopt-aligned` and `adopt` (a background reply). `--source` selects a previous ViewModel implementation. Use alternating fresh processes, discard a warm-up pair, and compare medians. Timers exclude fixture construction; process peak RSS includes it. This harness does not measure SwiftUI layout, rendered FPS or end-to-end app latency.
