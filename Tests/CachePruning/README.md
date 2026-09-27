# Read-side cache maintenance checks

Run `TMPDIR=<scratch directory> bash Tests/CachePruning/run.sh candidate checks`.
The runner compiles the real cache and API error source with optimization; the
only stub is the unrelated sidebar index data type. `baseline checks` runs the
same assertions against the audited upstream revision and should fail the
ten-minute maintenance assertion. Each run uses a fresh disposable directory.

`CacheChecks.swift` covers completed reads, scope separation, unauthenticated
reads, expired records between maintenance passes, clock rollback, immediate
write-budget enforcement, disabled/re-enabled caching and explicit clearing.

`CacheBench.swift` seeds fresh synthetic records, measures 25 warm reads at
10/100/1,000/5,000 files, and reports wall/CPU medians and p95. It removes only
its own generated cache directory. Run baseline and candidate alternately on
an otherwise idle machine. These component measurements are not app-opening
latency or device FPS; validate any perceived benefit separately in the app.

Run `baseline benchmark` and `candidate benchmark` alternately to reproduce the
component timing comparison. Do not compile or run other benchmarks concurrently.

The change keeps write-time size enforcement unchanged. Only read-side
directory maintenance is limited to once per ten minutes. Requested entries
are still checked individually for retention expiry on every read.
