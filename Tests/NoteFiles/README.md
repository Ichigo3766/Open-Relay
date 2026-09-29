# Native note attachment checks

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Contract inspected: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`,
`src/lib/components/notes/NoteEditor.svelte` and `backend/open_webui/routers/notes.py`.

## Focused checks

From the client checkout, with a temporary directory on the test disk:

```sh
TMPDIR=/path/to/test-disk python3 Tests/NoteFiles/baseline.py
TMPDIR=/path/to/test-disk python3 Tests/NoteFiles/run.py
```

The baseline probe compiles the pinned, unmodified Note model and reproduces the
ignored native `data.files` list. It also verifies that the old update method
does not serialize attachment references. The fixed checks compile the actual
production attachment model and files-only save API; only the transport and
upload boundary are mocked.

Coverage includes native/nested metadata, unknown fields, upload/save failures,
manual retry without re-uploading, refreshed lists, duplicate attachment IDs,
removal, read-only access, account/token changes, cancellation, malformed replies,
and valid empty/null note data. No Open WebUI modules are imported or executed.

## Full app fixture

Run `python3 Tests/NoteFiles/fixture.py`. Use a dedicated simulator connected only
to `http://127.0.0.1:18191`; sign in with `demo@example.test` and any synthetic
password. The fixture never contacts another server or model. Its authenticated
content endpoints and `/_test/state` counters verify explicit-only file loading.

For the import test, create `Folding Steps.txt` in this isolated app's Documents
directory with this freshly invented text:

> Fold a square sheet. Add a paper handle. This is a synthetic import test.

Generate the UI test project with `xcodegen generate --spec Tests/NoteFiles/project.yml`.
Run `NoteFiles` on the dedicated simulator with external DerivedData/results,
ad-hoc signing, and parallel testing disabled. Run only `testBefore` on the
baseline. Skip `testBefore` on the changed app. Never point these tests at a real
account; the fixture model name is checked before navigation.

The UI cases cover visible restored attachments, zero content requests on load
and scroll, native text/audio previews and play/pause, manual preview retry/cancellation,
failed removal, successful removal after retry, dark-mode reopening, import via
the system picker, retry after upload succeeds but note save fails, and read-only
attachment controls at largest Dynamic Type.

### Verified results

- Both baseline incompatibilities reproduce.
- All 39 focused production-model/API checks pass.
- The Release simulator app build passes.
- Four full-app cases pass on iOS 26.5: restored attachments/removal/reopening,
  audio play/pause, preview failure/retry/cancellation, and read-only large text.
  The fixture observed zero content requests for opening/scrolling the note and
  one authenticated request for each explicitly opened successful preview.
- The system-picker import case remains runtime-unverified. The picker displayed
  and selected the synthetic file, but Open never returned it to the application;
  File Provider reported errors and the fixture received zero uploads. Rebooting
  did not resolve it. Fresh simulator startup/installation was also blocked.
  Import/save/retry behavior is covered by the focused tests, with the existing
  upload API mocked; that is not a claim of a passing end-to-end picker import.

## Scope

- Saves replace only `data.files`; the server shallow-merges outer note data.
  Rich content, versions, title, sharing, and unknown attachment fields are not
  reconstructed. The latest list is fetched before mutation; the native API still
  has last-write semantics for truly simultaneous clients.
- Existing uploaded files use authenticated, user-initiated disk downloads and
  native Quick Look. Formats supported by Quick Look can be previewed/shared.
  Unsupported native reference types remain in the list and in subsequent saves.
- Native inline base64 images are decoded only on tap. Arbitrary external image
  URLs are not fetched with authentication. They remain preserved but report an
  unsupported preview when opened.
- Imports reuse the existing upload/processing API. A successful upload followed
  by a failed note save retains the reference for retry while the editor remains
  open. This is not an offline upload queue or durable recording-recovery feature.
- Removing an attachment removes the note reference, not the server's underlying
  file. Preview dismissal removes its temporary preview directory.
- No shared chat attachment, Knowledge picker, search, or terminal code changes.

Only reviewed, synthetic PNG screenshots belong in the published change. Do not
commit result bundles, diagnostic logs, screen recordings from failed tests,
app-container files, or real configuration.
