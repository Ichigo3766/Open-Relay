# Read-side cache maintenance checks

Compile each test executable with `swiftc -O -parse-as-library`, including the
real `Open UI/Core/Services/ConversationCache.swift` and
`Open UI/Core/Networking/APIError.swift`. The only stub is the unrelated sidebar
index data type. Pass a disposable scratch directory to each executable.

`CacheChecks.swift` covers completed reads, scope separation, unauthenticated
reads, expired records between maintenance passes, clock rollback, immediate
write-budget enforcement, disabled/re-enabled caching and explicit clearing.

`CacheBench.swift` seeds fresh synthetic records, measures 25 warm reads at
10/100/1,000/5,000 files, and reports wall/CPU medians and p95. It removes only
its own generated cache directory. Run baseline and candidate alternately on
an otherwise idle machine. These component measurements are not app-opening
latency or device FPS; validate any perceived benefit separately in the app.

The prototype keeps write-time size enforcement unchanged. Only read-side
directory maintenance is limited to once per ten minutes. Requested entries
are still checked individually for retention expiry on every read.
