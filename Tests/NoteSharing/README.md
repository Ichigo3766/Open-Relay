# Native note sharing

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`.

The note editor has no native access-management action on the baseline.
The new Note Actions → Manage Access sheet loads the current server grants and
uses `POST /api/v1/notes/{id}/access/update`. The body contains only
`access_grants`; it never rewrites title, content, files, versions, or pins.

Owners and administrators can manage user/group read and edit access, or access
for all signed-in users, subject to the server's sharing permissions. Native
edit access requires both read and write grants. The server remains authoritative:
the UI adopts its returned grants, serializes changes, and retains the previous
confirmed state on failure. No global retry policy is changed. Unknown principals
are preserved rather than silently removed by an unrelated edit.

The person picker uses server search and manual pagination; group search filters
the native group-list response. Selecting a person/group initially grants read
access. Existing permissions can be changed or removed from the main sheet.
Closing the sheet does not roll back changes that the server has already saved.
There is no anonymous sharing or custom public URL mechanism.

## Focused verification

```sh
python3 Tests/NoteSharing/run.py
```

This compiles the production model and API methods against synthetic transport.
It checks exact path/body, explicit read-plus-write grants, all access choices,
permission restrictions, unknown grants, failures/manual retry, server-filtered
responses, malformed acknowledgements, concurrent taps, cancellation, and
account/token changes. An interrupted request may already have reached the
server; reopening reloads authoritative access rather than claiming rollback.

## Full-app reproduction

Start `python3 Tests/NoteSharing/fixture.py`. In an isolated simulator, sign in to
`http://127.0.0.1:18191` with invented credentials. The fixture cannot connect to
a real instance and accepts only its synthetic bearer token for sharing changes.
It exposes one invented note, four invented readers, and an invented group.

Run `xcodegen generate` in this directory, then run the `NoteSharing` scheme with
an explicit simulator destination, external build directory/result bundle,
`-parallel-testing-enabled NO`, and `-collect-test-diagnostics never`.
`testBefore` runs only against the baseline; the other tests run against the
changed Release app. They cover user search/pagination, user/group grants,
public read access, editing/removal, relaunch, failure/manual retry and a
read-only note. Screenshots are actual simulator UI, not mockups.

Do not publish app containers, raw logs, result bundles, user data, or credentials.
Only reviewed synthetic screenshots belong in `Screenshots`.

The HTTP fixture verifies the client contract, not a live production permission
deployment. Server permission behavior was independently reviewed in the public
Notes router, access-grant model, and native AccessControl component.

## Verified results

- All 36 focused production-code checks pass.
- Full Release simulator build passes.
- Baseline simulator reproduction confirms the absent access-management action.
- Full-app sharing and failure/read-only tests pass on iOS 26.5, including the
  exact native read-plus-write payload, manual retry (two attempts total), server
  user search/page requests, grant removal, and persisted state after relaunch.
- The largest Dynamic Type size remains scrollable, with reachable controls and
  a visible native Close button. The initial test incorrectly required an
  offscreen row before scrolling; the corrected test passes.

No personal instance or live multi-user deployment was used. Names fall back to
principal IDs if the corresponding directory record cannot be resolved. Access
updates use the native replacement-list API, which has no conditional version
check; simultaneous edits by multiple clients have the same last-write behavior
as the web client.
