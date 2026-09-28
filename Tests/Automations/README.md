# Automation configuration regression checks

Run `python3 Tests/Automations/run.py` with Xcode's Swift compiler selected.
Set `TMPDIR` to choose where temporary build products are stored.

The runner compiles the production Automation model and the exact API/update
view-model methods. A deterministic transport records requests and returns fresh,
invented JSON; it does not contact an instance or execute server code.

Coverage includes terminal-enabled list decoding, optional terminal fields,
preservation of paused state, channel target, terminal, folder, nested metadata,
all four edited fields, malformed snapshots, network/update failures, and
cancellation before submission. A failed save remains unsaved in the editor.

Baseline: Open Relay `f5b8ce858cd790718a31107d954e6cfe32704bb2` (5.9).
The initial regression checks failed on baseline (7/20 passed); the fixed version
passes all 25 checks, including the added save-result/cancellation checks.
These are contract tests with a mocked transport, not a live-server stress test.

The current server replaces the automation form on update, so saving fetches the
latest snapshot and changes only name, prompt, model, and schedule. This avoids
resetting fields that have no control in the mobile editor. It is not an atomic
compare-and-swap: the server does not offer a conditional-update contract, so a
concurrent web edit after that fetch can still race with the save.

No new screens or visual styling are introduced. All fixture data is synthetic;
no personal chats, instance configuration, media, or credentials are included.
