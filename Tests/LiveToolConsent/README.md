# Live tool consent regression

Baseline: Open Relay 5.9 (`f5b8ce8`), Open WebUI `8bd8b4f`.

The active-chat socket path answered `confirmation` with `true` immediately,
ignored `input`, and only logged `notification`. This is separate from message-action
dialogs, which already existed. The fixture sends real Socket.IO calls to the
session that initiated the synthetic chat.

## Focused checks

Run `python3 Tests/LiveToolConsent/run.py`. The production prompt state is compiled
and exercised with mock callbacks: no implicit approval, queued requests, exact
input values, once-only replies, stale taps, cleanup, malformed calls, default
values, select/password input metadata, notifications after completion, and
rejection of acknowledgments from an old/disconnected socket session. Reply contents
are no longer logged, including values from password inputs.

`python3 Tests/LiveToolConsent/run.py --baseline` compiles the original confirmation
handler from `origin/main`. It intentionally fails because the callback fires
before the user answers. It requires the recorded baseline at `origin/main`.

## Simulator reproduction

Use an isolated simulator and a Python environment containing `aiohttp` and
`python-socketio`. Run `fixture.py` (loopback port 18191), connect Relay to
`http://127.0.0.1:18191`, and sign in with `demo@example.test` / `synthetic`.
Install the app version to test, generate `project.yml` with XcodeGen in this
directory, and run the `LiveToolConsent` scheme's UI tests:

- Baseline: `testBefore` verifies the server received `true` without a confirmation
  tap, while the input request has no UI.
- Fixed: `testConsent` verifies no callback precedes the explicit tap, then checks
  the confirmation and input responses received by the server and the notification.
- `testCancel` checks both cancellation callbacks return `false`.

All content is invented. The fixture never imports Open WebUI, contacts a provider,
or reads a real server's settings or chats. Test logs/result bundles are not published.

Prompt state is transient and per chat; it is not a durable approval history.
Finishing/stopping the stream cancels pending calls. A disconnected socket cannot
deliver a response to a departed server session; this does not promise replay of
expired calls. Generic JavaScript execution and `ask_user` are separate workflows.
