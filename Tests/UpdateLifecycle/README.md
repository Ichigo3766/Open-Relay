Run from the repository root, keeping generated files outside the checkout:

```sh
python3 Tests/UpdateLifecycle/run-tests.py /path/outside/checkout/update-checks
```

The runner compiles the actual automatic-update task bodies with invented
checkers. Only the presentation delay is accelerated, from 1.2 seconds to
50 milliseconds. No requests reach an external service.

Eight checks exercise overlapping authentication/foreground launch paths,
parallel app/server checks, foreground returns, inactive/background phases,
cancelled delays, and a rapid inactive-active transition. This isolates task
scheduling; the native integration separately verifies SwiftUI lifecycle events
and counts requests against synthetic loopback responses.

Use `--source-root /path/to/another/checkout` for the unmodified-source comparison.
At `3e721e3`, the cold-launch paths start two app and two server check batches;
the candidate starts one of each and still checks again on foreground return.
