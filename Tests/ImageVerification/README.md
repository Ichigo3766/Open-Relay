# Image connection verification regression

Run `python3 Tests/ImageVerification/run.py` with Xcode selected. `TMPDIR`
controls temporary compiler output.

The runner compiles the exact production API and view-model methods with a
deterministic transport. It adapts only the call signature to allow the same
contract assertions to run against the old no-argument API.

On Open Relay 5.9 (`f5b8ce8`), six of eleven checks failed: verification saved
configuration first, called the obsolete GET endpoint, omitted the selected
engine/URL/key, and hid malformed responses. All eleven pass with this fix.

The current contract is `POST /api/v1/images/verify` with `engine`, `url`, and an
optional `key`, returning a JSON Boolean. The ComfyUI button passes its own field
bindings, so image editing verifies its own connection rather than the generation
connection. Verification no longer invokes configuration update at all.

Tests also cover false responses, network failures, loading/result state, and an
omitted key. The transport is mocked; no real image engine is contacted. All
URLs and keys are explicitly synthetic. No UI layout changes are introduced.
