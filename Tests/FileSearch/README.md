# Files search verification

Run the focused checks with `bash Tests/FileSearch/run.sh`. They compile the
production search model and API extension with a transport double, covering
pagination, metadata, request parameters, no-match/error handling, cancellation,
stale responses, and deduplication against Knowledge document results.

## Simulator checks

Use an isolated simulator, never a personal account or existing library.
The fixture invents all models, files, text, and account information from scratch.

1. Run `python3 -B Tests/FileSearch/fixture.py` on the host.
2. Build and install Open Relay on the isolated iPhone simulator.
3. Generate the standalone UI-test project using
   `xcodegen generate --spec Tests/FileSearch/project.yml --project Tests/FileSearch`.
4. Run the `FileSearchTests` scheme on that simulator, excluding `testBefore`.
   That test is specifically for capturing the unmodified baseline.

The tests connect to `http://127.0.0.1:18191` and use the fixture's demo sign-in.
They cover light/dark search, pagination, PDF/text previews, sharing, empty
results, failures, retry, cancellation, and metadata-only search requests.
`/_test/metrics` exposes only the fixture's in-memory request paths, query
parameters, and an authorization boolean—not credentials or external logs.
Named screenshot attachments are retained in the XCTest result bundle.

Files search uses the native filename/wildcard search API; it does not add
full-text search across arbitrary uploads. Documents is a separate top-level
filter for the existing Knowledge document-content search. Knowledge still
includes its bases and documents.
Opening a file explicitly downloads that file to temporary disk for Quick Look
and sharing. Search rows do not download original files or thumbnails.
