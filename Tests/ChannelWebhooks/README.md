# Native channel webhooks

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`,
`routers/channels.py`, `models/channels.py`, `src/lib/apis/channels/index.ts`.

## Focused tests

Run `python3 Tests/ChannelWebhooks/run.py` with a Swift compiler. The 32 checks
compile the actual models, API methods, observable state, and permission expression
with synthetic networking/auth stubs. They cover routes and native payloads,
nullable/preserved profile images, invalid responses, server manager state,
administrator/member gating, URL construction under a server prefix, mutation
failures, duplicate submissions, and stale-account reads/writes/copy actions.
No token is automatically copied, displayed, or written to local preferences.

## Simulator fixture

Use an isolated app/simulator with an `aiohttp` test environment. Run
`python3 Tests/ChannelWebhooks/fixture.py`, then sign into
`http://127.0.0.1:18191` with `demo@example.test` and a synthetic password.
The fixture creates only invented channel and webhook records and never contacts
an upstream service. Its bearer and webhook tokens are inert fixture constants.

Generate the UI project with `xcodegen generate` in this directory. Run the
`ChannelWebhooks` scheme against an available simulator, with an ad-hoc-signed
runner (`CODE_SIGN_IDENTITY=-`) and DerivedData/result bundles outside the repo.

- `testBefore`, on the unchanged channel path: channel settings contain no webhook
  management. The baseline screenshot uses an otherwise unrelated 6.0-based app.
- `testManagement`, on the changed app: list, explicit copy, failed rename retaining
  the entered name, retry preserving the existing image, create, and confirmed delete.
- `testPermissionRetry`: denied access hides records and disables creation; a manual
  retry after permission recovery loads them.

Skip `testBefore` when running the changed-app cases. Do not mix these tests with
real accounts. Raw diagnostic bundles/logs are deliberately excluded from the repo.

Validation: 32 focused checks, a full Release simulator build, the baseline case,
and both changed-app cases passed on iOS 26.5. Initial harness runs needed locator
corrections for the existing “Channel Name” field and the networking layer's
friendly 503 message; the final cases pass against those actual native labels.
Screenshot contents and image metadata were reviewed for privacy.

## Scope and security

Managers and administrators can open Webhooks from Channel Actions. Server
authorization remains authoritative. Native authenticated list/create/update/delete
routes are used without automatic mutation retries. An ambiguous network failure
may still have reached the server; no exactly-once claim is made.

Copy is explicit, local-device-only, and expires from the clipboard after five
minutes. URLs contain the webhook's posting token, not the account bearer token;
the screen warns that anyone possessing one can post. Renaming preserves existing
profile images. Image customization is not added here. No outgoing test message,
external integration, provider, or webhook delivery is exercised by the fixture.
