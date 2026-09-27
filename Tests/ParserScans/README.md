# Reasoning parser scan experiment

Run `TMPDIR=/path/to/external/scratch bash Tests/ParserScans/run.sh` from the
checkout. Add `--benchmark` for alternating Release CPU comparisons against
the public baseline identified in the script. No server or app data is read.

The script mechanically extracts the real parser, compiles both revisions,
and compares ordered segments, reasoning metadata and tool results. Fixtures
cover all reasoning tag spellings, mixed case, adjacent combining marks,
entities, malformed/nested tags, partial streaming prefixes and deterministic
mixtures. Synthetic text only. Benchmarks measure parser CPU, not displayed FPS
or model/network latency.
