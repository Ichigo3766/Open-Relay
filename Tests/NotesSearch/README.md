# Notes server search regression

Baseline: Open Relay 5.9 (`f5b8ce8`), Open WebUI `8bd8b4f`.

The native `/api/v1/notes/search` response is `{items, total}`, not a bare array.
The baseline API discards that envelope; its manager then substitutes cached
matches for empty results. The Notes list also never calls `triggerSearch()` when
the query changes. Together these make server-only matches unreachable.

Run `python3 Tests/NotesSearch/run.py` for the focused checks. They compile the
actual API/manager search methods, Note model, and NotesListViewModel with an
in-memory transport. Coverage includes decoding, query/page parameters, legacy
arrays, malformed responses, authoritative empty results, local-only mode,
pagination, retry, duplicate requests, stale responses, single-character queries,
clearing, and returning to an active search. `--baseline` intentionally fails on
the original envelope decoder from the recorded `origin/main` revision.

For simulator reproduction, run `python3 Tests/NotesSearch/fixture.py`, connect an
isolated Relay simulator to `http://127.0.0.1:18191`, and sign in with
`demo@example.test` / `synthetic`. Open Notes and search for `paper`. The initial
list contains only Catalog Index; server search returns Paper Star 1 and 2, then
Load More retrieves Paper Star 3. The deliberately small pages check that the
client uses `total` rather than hard-coding the server's normal page size.

Generate the test project from `project.yml` in this directory using XcodeGen.
Run `testBefore` on the baseline and `testSearch` on the fixed app; the latter
checks both displayed results and the query/page requests received by the fixture.

The fixture is newly invented, loopback-only, and does not read private data or
import/run Open WebUI. Build logs and test result bundles are not published.
This fix concerns the Notes list, not the separate Attach Note picker or the
note editor's rich-text/pinning behavior.
