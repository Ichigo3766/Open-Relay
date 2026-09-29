#!/bin/sh
set -eu
root=$(git rev-parse --show-toplevel)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/relay-note-chats.XXXXXX")
trap 'rm -f "$test_output/checks"; rmdir "$test_output"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$root/Open UI/Core/Services/NoteChatSession.swift" \
  "$root/Open UI/Core/Models/Note.swift" \
  "$root/Tests/NoteChats/Checks.swift" -o "$test_output/checks"
"$test_output/checks"
