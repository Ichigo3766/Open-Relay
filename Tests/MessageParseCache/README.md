# Message parse cache regression checks

Run on macOS with Xcode's Swift compiler and Python 3:

```sh
python3 Tests/MessageParseCache/run-tests.py
```

The runner extracts the current production cache and parser into a temporary
compilation unit, leaving their implementation unchanged. It excludes SwiftUI
views and the unused file-extraction method, so no app, simulator, server, or
external packages are needed. It uses the app's Swift 5 language mode and
MainActor default isolation. Generated files are removed when the runner exits.

All inputs are freshly invented. Checks cover equal-length/common-prefix
messages, synchronous and actor lookups, warm batches, Unicode tails, content
edits, and concurrent requests. Tool fixtures omit IDs so reparsing can be
detected by a changed generated UUID, not just by equivalent visible output.

The original prefix/length cache key fails the retention and reuse checks.
