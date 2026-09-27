# Composer token experiment

Compile `Open UI/Shared/Components/ComposerToken.swift` with this folder's
`main.swift` using `swiftc -O`, writing the executable to a scratch directory.
Run it for deterministic cursor/Unicode and randomized reference checks;
add `--benchmark` for alternating comparisons against the original four scans.
Use `--editing-benchmark` for a new edit on every sample, with both end-of-draft
and middle cursors. This avoids presenting warmed String indexing as the cost
of processing a newly edited Unicode draft. Timing wrappers are not inlined.

The original implementation counts Swift Characters using a UIKit UTF-16 cursor
offset and scans the entire preceding draft separately for each trigger. This
prototype examines the current token once. It retains the existing behavior for
repeated trigger characters within a word. Benchmarks cover token detection only,
not keyboard latency or the rest of UITextView layout.

`TMPDIR=<external scratch> bash Tests/ComposerToken/run-coordinator.sh candidate`
extracts the actual delegate and tests a re-entrant layout refresh for all four
triggers. The baseline variant intentionally fails: it detects against the
temporarily restored old text. Capturing the edited token at delegate entry
keeps whitespace dismissal and query updates correct. This controlled test
models the numeric full-app trace; simulator integration is checked separately.

The Release iOS 27 app passed three consecutive XCUITest repetitions, checking
all four trigger pickers and their dismissal after an asserted space insertion.
The baseline failed that dismissal in two runs; the problem is timing-sensitive,
not a failure on every edit. The numeric diagnostic records lengths and cursor
positions only, never draft text.
One passing candidate repetition still captured the same 7-to-6-character
re-entrant replacement, with the setter called through updateUIView. The picker
nevertheless dismissed correctly, so this was not only a run where the race
failed to occur. This change does not remove the underlying transient text reset.
