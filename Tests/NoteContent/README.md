# Preserve note content during metadata changes

Initial baseline: Open Relay 5.9 (`f5b8ce8`); Open WebUI `8bd8b4f`.
Rebased on Open Relay 6.0 (`4151a73`): all 18 checks and the full Release
simulator build pass. The unchanged 6.0 implementation also fails the rename probe.

Run `python3 Tests/NoteContent/run.py`. The production Note model, API methods,
and manager update method run against a mocked transport with the native server's
outer-data shallow-merge semantics. No server modules or private data are used.
`--baseline` intentionally fails: a rename replaces the rich content object.

The fix omits `data.content` unless the editor explicitly changed its body, and
uses the native lowercase `html` key for intentional content writes. Markdown
body edits still replace the rich representation deliberately; this is not a rich
document editor. Failed saves keep the editor's original comparison baseline and
dirty indicator, so a later save can retry the body rather than treating it as
already synchronized. This does not add an offline synchronization queue.

Checks cover renaming, local attachment bookkeeping, explicit Markdown edits,
outer file/version preservation, failed saves and retry, HTML-only/legacy parsing,
creation, and local-only storage. Source checks cover the editor's change tracking.
