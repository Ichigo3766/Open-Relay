# Nullable calendar color regression

Run `bash Tests/CalendarColor/run.sh` on macOS with Xcode selected. `TMPDIR`
controls the location of temporary compiler output.

This compiles the actual calendar model and SwiftUI color helpers. Synthetic
fixtures cover a missing color, JSON null, valid/invalid hex strings, mixed
calendar lists, and encode/decode round trips. No network or instance is used.

On Open Relay 5.9 (`f5b8ce8`), the original seven checks reproduced five failures:
one uncolored calendar rejects the entire list. With the fix, all nine checks
pass (the two additional round-trip checks run after null decoding succeeds).

The change only accepts the server's nullable field and reuses the existing blue
display fallback. It does not change configured colors or introduce a new UI.
