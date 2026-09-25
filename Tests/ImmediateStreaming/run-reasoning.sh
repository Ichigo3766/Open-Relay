#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/relay-reasoning-tests.XXXXXX")
source_file="$repo/Open UI/Shared/Components/ToolCallView.swift"
flags=()
if [[ -n "${RELAY_REASONING_REF:-}" ]]; then
    git show "$RELAY_REASONING_REF:Open UI/Shared/Components/ToolCallView.swift" > "$scratch/Source.swift"
    source_file="$scratch/Source.swift"
    flags+=(-D REASONING_BASELINE)
fi
# Compile the real pure parser, excluding UIKit views and file-model integration.
awk 'BEGIN { print "import Foundation\nimport os" }
 /^struct ToolCallData:/ { copying=1 }
 /^    \/\/ MARK: - File ID Extraction/ { copying=0; print "}" }
 copying { print }' "$source_file" > "$scratch/Parser.swift"
swiftc -O -swift-version 5 -parse-as-library ${flags[@]+"${flags[@]}"} "$scratch/Parser.swift" \
    "$repo/Tests/ImmediateStreaming/ReasoningTests.swift" -o "$scratch/tests"
"$scratch/tests" "$@"
