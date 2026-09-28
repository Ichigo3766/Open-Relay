# Web search consent

Baseline: Open Relay 5.9 (`f5b8ce8`), Open WebUI `8bd8b4f`.

`python3 Tests/WebSearchConsent/run.py` compiles the production feature decoder and
consent state against a mocked API. It checks 18 cases plus routing of send,
regenerate, continue, edit, voice-call startup, account reset, and model-refresh
cancellation. `--baseline` intentionally fails because the original decoder drops
the server's required-confirmation flag.

Consent is per chat, cached while web search remains enabled, and reset on disabling
search, starting a new chat, or changing accounts. Leaving the view cancels a pending
operation. Model defaults refresh before asking, so a newly enabled default does not
bypass consent. A config error fails closed without clearing the draft. The server's
notice is shown as text in a native alert; no HTML or JavaScript is executed.

For actual app checks, start `fixture.py` in a Python environment with `aiohttp`
and `python-socketio`, then connect an isolated simulator to `http://127.0.0.1:18191`
using `demo@example.test` / `synthetic`. Run XcodeGen with `project.yml`, install
the app build, and run the `WebSearchConsent` scheme:

- `testBefore`: the original app sends a search-enabled completion without an alert.
- `testConsent`: no chat or request exists before consent; Cancel retains the draft;
  retry and Continue send exactly one search-enabled request and show the response.
- `testDisabledPolicy`: no dialog when the server disables confirmation.

All fixture data is invented. It contacts no search provider or private server.
The UI checks cover chat consent; voice audio/provider behavior is not benchmarked.
