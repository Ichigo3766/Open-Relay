# Absent chat-preference cache regressions

Run on macOS with Python 3 and Xcode command-line tools:

```sh
python3 Tests/EmptyPinnedModels/run-tests.py /external/scratch
/external/scratch/checks --benchmark
```

The runner extracts the production pin-list and message-queue settings methods into fresh observable models sharing a synthetic session cache. Generated sources, binaries, temporary objects, and module caches stay outside the checkout. No app data or existing settings are read.

Checks cover absent/null UI fields and absent pin/queue fields, explicit empty/populated lists and booleans, malformed UI/pin/queue values, failure/retry, cached edits, separate session caches, session invalidation during suspended requests, and missing manager/store. `--source` accepts a prior ChatViewModel.swift for the failing control.

The optional benchmark opens sixty component models sharing one cache, fetching both preferences, with a 5 ms simulated request delay. Request counts and response JSON bytes come from the synthetic transport. Its elapsed time includes the invented delay; it is not a UI navigation, wire-byte, radio, or real-server latency measurement.
