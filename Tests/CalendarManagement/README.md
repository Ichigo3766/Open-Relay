# Calendar management regression coverage

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Native contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`,
`routers/calendar.py`, `models/calendar.py`, and `src/lib/apis/calendar/index.ts`.

## Focused tests

Run `python3 Tests/CalendarManagement/run.py` with a Swift compiler. It compiles
the actual calendar models and extracted API/management methods against synthetic
transport; only SwiftUI color rendering is stubbed. Checks cover native routes,
rename-only payload preservation, list/visibility updates, protected calendars,
default selection, failures, duplicate/overlapping actions, and account switching.

## Simulator

Use an isolated simulator/app. In an environment containing `aiohttp`, run
`python3 Tests/CalendarManagement/fixture.py`. Sign into `http://127.0.0.1:18191`
with `demo@example.test` and a synthetic password. The loopback fixture does not
contact a server, provider, or real calendar account.

Generate the UI project with `xcodegen generate` in this directory. Run the
`CalendarManagement` scheme on an available simulator using an ad-hoc-signed
runner (`CODE_SIGN_IDENTITY=-`); put DerivedData and results outside the repo.

- `testBefore`: unchanged calendar path has no Manage Calendars action.
- `testManagement`: native list/editor, protected default/system calendars,
  failed rename retaining the draft, retry preserving sharing/data, creation,
  default change, destructive confirmation/deletion, and relaunch persistence.
- `testCancel`: dark-mode editor and cancellation without a write.

Run the baseline case separately from the changed-app cases. All fixture records
are freshly invented. Do not use real accounts or publish raw diagnostic bundles.

## Scope

Calendar owners/admins get edit and delete controls; only owned calendars can
become the user's default. System/default calendars cannot be deleted. Shared
calendar write grants remain server-authoritative; this change does not add a
sharing editor or infer group membership. Metadata and access grants are omitted
from rename/color requests so the server preserves them.

Requests are single-attempt. Errors keep the editor open and require explicit
retry; an ambiguous failed write may have reached the server. No exactly-once
guarantee is claimed. Event editing/recurrence and nullable-color decoding are
separate changes, not duplicated here.
