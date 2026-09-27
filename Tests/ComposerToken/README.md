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
