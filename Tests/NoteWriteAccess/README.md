# Read-only shared notes

Baseline: Open Relay 6.0 (`4151a735512d5d6dbc9fd1962fa806517a0d4ea7`). Contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`, `GET /api/v1/notes/{id}` returns `write_access`, including effective group/public access. The server remains the authority for every write.

## Reproduction

Serve the invented `Paper Lanterns` note with `write_access: false`. Open Notes, then that note. Baseline offers Edit, AI Features, Record Audio, and Attach File. Editing the title attempts an update that the fixture rejects with 403.

The fix retains the flag, shows Read Only, removes unavailable editing controls, and guards the save path before either the local cache or server is changed. Notes with write access remain editable. Missing flags preserve compatibility with older responses/caches; this does not grant server access. Live permission revocation is still enforced by the server, not a new subscription in this change.

## Focused checks

```sh
python3 Tests/NoteWriteAccess/run.py
python3 Tests/NoteWriteAccess/run.py --baseline
```

The second command deliberately fails: the baseline decoder discards read-only access. The fixed suite compiles the actual note model and save method and tests explicit true/false, legacy missing state, cache decoding, equality, local-write prevention, and authorized/offline saves.

## Simulator

Run `fixture.py` on loopback port 18191 with a standard Python 3 interpreter. Connect an isolated simulator to it with the invented account `demo@example.test` (any test password). It issues only the synthetic token `synthetic-token`; it never contacts another service.

Generate the test project with `xcodegen generate` in this directory. Run `testBefore` on baseline and the other cases on the changed app, using the installed simulator and external build storage. The tests check native UI controls, light/dark appearance, and update requests counted by the fixture. No AI or recording action is executed.

Only explicitly captured, reviewed PNGs belong in `Screenshots/`. Raw test bundles, UI hierarchies, logs, recordings, and credentials must not be published.

Verified: all 14 focused checks, Release simulator build, baseline UI reproduction, and both fixed UI cases passed on iOS 26.5. The baseline screen used a 6.0-based build with unchanged Notes sources. The fixed cases cover read-only light/dark views and writable/legacy saves. All three published PNGs were visually and metadata reviewed.
