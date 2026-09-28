# Model-defined chat variables

Baseline: Open Relay 6.0 (`4151a735`), compared with Open WebUI
`8bd8b4fa`. Only freshly invented craft-planning data is used here.

## Focused checks

Run `python3 Tests/ChatVariables/run.py` from the repository root. The harness
compiles the actual model, schema adapter, completion request, variable-save
method and API method with isolated transport/lifecycle stubs. It covers
required inputs, defaults, native scalar types, numeric validation, cached
schemas, preservation of unknown values, failures, single-flight saves and
chat/account/draft changes during asynchronous saves.

## App reproduction

In an isolated simulator, run `fixture.py` with `aiohttp` and `python-socketio`
installed in a disposable environment. Connect Relay to `http://127.0.0.1:18191`
using the fixture's invented account. Never point these tests at a real server.
Generate the UI test project with XcodeGen in this directory and run the
`ChatVariables` scheme against the separately installed app.

- `testBefore`: the unmodified variables path has no Controls entry and sends
  a request without collecting the model's required inputs.
- `testSavedVariables`: the form blocks sending, retains input after a failed
  save, retries explicitly, saves native JSON types and preserves other keys.
  Saving does not send a message. Reopening restores the values.
- `testNewChatVariables`: a failed chat creation preserves the draft; retry
  creates the chat with its variables before requesting a response.
- `testTemporaryVariables`: variables use the native completion fallback
  without a server chat save, and survive promotion to a permanent chat.

The fixture checks request bodies and authentication independently of the UI.
No model provider is contacted. Test results, screenshots and build logs must
be stored outside the source tree; only explicitly reviewed synthetic images
belong in `Screenshots/`.

## Scope

This adds inputs for the currently selected model (including an explicit
model mention), reusing the existing prompt-variable controls. It does not add
simultaneous multi-model selection or a schema editor. Map/month inputs retain
the existing text-entry fallback. A refresh-before-merge preserves unrelated
variable keys, but the server has no compare-and-swap API: concurrent edits to
the same key remain last-writer-wins.
