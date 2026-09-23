# Reasoning parser regression checks

On macOS with Xcode's Swift compiler, Python 3, and the repository's Git history:

```sh
python3 Tests/ReasoningParsing/run-tests.py
python3 Tests/ReasoningParsing/run-tests.py --benchmark
python3 Tests/ReasoningParsing/run-tests.py --benchmark --require-speedup
```

The runner extracts the unchanged production cache/parser, excluding unrelated
SwiftUI views and the unused file-extraction method. It compiles alongside a
reference parser from public upstream commit
`3765c48ab2a79af59ce39e4fc0d704491836648e`, using the app's Swift 5 language mode
and MainActor default isolation. No app, server, simulator or packages are needed.
All generated files are temporary. A shallow checkout must first fetch that
public commit to run the reference comparison.

All data is freshly invented. Checks compare segment order and contents,
reasoning metadata, tool fields and embeds across all supported reasoning tags,
case variants, Unicode, nested details, quoted attributes, orphan closers and
every incremental prefix of the details fixtures. Randomly generated tool IDs
are excluded from equivalence comparisons.

The optional benchmark alternates current/reference calls over a long synthetic
completed reasoning block and reports both medians. `--require-speedup` also
requires the current median to be less than half the reference median; this
fails on the unoptimized parser on the affected runtime. Do not require that
speedup on older Foundation versions that may already implement efficient search.
This is not an absolute latency or frame-rate claim. Run without competing
builds for comparison; the default correctness checks have no timing threshold.
