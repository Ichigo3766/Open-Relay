# Synthetic regression checks

Run on macOS with Python 3 and the Xcode command-line tools. Inputs are freshly invented; the runner never reads app containers, credentials, server configuration, or existing chats. Generated sources, binaries, and module caches must stay outside the checkout.

```sh
python3 Tests/MessageParseCache/run-tests.py /external/scratch
/external/scratch/checks --benchmark
/external/scratch/checks --benchmark-warm

```

The runner compiles the production parser, cache, initial-window selection, and relative-URL resolver with small model stubs. Checks cover canceled work, visible parsing/cache reuse, plain versus structural warming, URL resolution, user-message exclusion, and sampled Unicode/marker edge cases. `--root` accepts a prior checkout for the failing control; when that revision lacks the shared classifier, the runner adapts its existing `isPlainText` predicate.

The benchmarks use twelve distinct invented messages totaling about 15 MB. `--benchmark` cancels gated parse jobs before the actor starts them; it does not claim to interrupt a parse already running. `--benchmark-warm` measures the initial-window selection plus cache warming of long plain answers with relative Markdown links. Allocate inputs before timing, alternate fresh-process controls, exclude the first pair, and report CPU, elapsed time, and peak RSS separately. These are component measurements, not UI frame-rate or network results.
