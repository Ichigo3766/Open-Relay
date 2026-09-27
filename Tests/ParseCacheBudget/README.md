# Parse-cache budget experiment

The harness extracts the actual cache and parser, then inserts 200 freshly
invented reasoning snapshots in a separate process per variant. It reports
physical footprint and retained entries, then verifies reparsing under pressure.
Pass `--warm` to exercise the batch-warming insertion path instead.

Run `TMPDIR=<external scratch directory> bash Tests/ParseCacheBudget/run.sh baseline`
and repeat with `candidate`. NSCache's cost limit is advisory, not a strict
physical-memory ceiling. These are component measurements, not app totals.
