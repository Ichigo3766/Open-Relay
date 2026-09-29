#!/bin/sh
set -eu
root=$(git rev-parse --show-toplevel)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/relay-note-drafts.XXXXXX")
swiftc -swift-version 5 -parse-as-library \
  "$root/Open UI/Core/Services/NoteDraftStore.swift" \
  "$root/Open UI/Core/Models/Note.swift" \
  "$root/Open UI/Features/Notes/ViewModels/NotesListViewModel.swift" \
  "$root/Tests/NoteDrafts/Checks.swift" -o "$test_output/checks"
"$test_output/checks" "$test_output/data"
echo "Synthetic test artifacts: $test_output"
