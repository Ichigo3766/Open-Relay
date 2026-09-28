# Tool connection regression coverage

Baseline: Open Relay 6.0 (`4151a735`). Native contract reviewed against Open WebUI
`8bd8b4fa`: `IntegrationsMenu.svelte`, `apis/configs/index.ts`, `/auth`, and the
server OAuth authorize/callback routes.

`python3 Tests/ToolOAuth/run.py` compiles the actual tool model, decoding,
authorization URL, send preflight, and connection refresh against synthetic
transport. `--baseline-auth` substitutes the baseline decoder and must fail the
explicit unauthenticated check.

55 focused checks pass; the baseline decoder fails that regression. Both Release
simulator builds pass. Actual iOS 26.5 tests pass for the baseline and all four
changed-app cases: browser connection, blocked draft/retry with a rendered answer,
failed status check/retry and quick pill, and declining a model-default tool.
The last case verifies that refreshing model defaults does not re-enable a tool
the user declined. All six screenshots and their metadata were privacy-reviewed.

For UI tests, run `fixture.py` with `aiohttp` and `python-socketio`. It binds only
loopback ports 18191 (synthetic app API) and 18192 (synthetic provider page).
Connect an isolated simulator to `http://127.0.0.1:18191`, using
`demo@example.test` and a synthetic password. No real account or provider is used.
Generate the project with `xcodegen generate`, then run the ToolOAuth scheme with
an ad-hoc-signed runner; keep build products and result bundles outside the repo.
Run `testBefore` only on the baseline app and the other cases on the changed app.

The browser fixture verifies navigation, separate browser cookies, return/check,
and absence of app authorization headers at both browser and provider routes. It
does not implement a real provider token exchange. Actual provider compatibility
is therefore a source-contract conclusion, not a provider integration test.

Safari can require another sign-in with the same Open WebUI account. Custom proxy
headers and the app bearer token are intentionally not forwarded to the browser.
There is no invented callback scheme or assumption that closing Safari succeeds.
The server's tools endpoint must report the tool as authenticated before sending.

All prompts, accounts, and provider pages here are freshly invented. Do not
publish raw diagnostic bundles or reuse personal accounts, chats, or screenshots.
