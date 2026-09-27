#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:?Set TMPDIR to external test storage}/relay-parser-scans.XXXXXX")
source_file='Open UI/Shared/Components/ToolCallView.swift'
# Mechanical extraction compiles the real parser, without unrelated UI types.
git show "f5b8ce858cd790718a31107d954e6cfe32704bb2:$source_file" > "$scratch/Baseline.swift"
awk 'BEGIN { print "import Foundation\nimport os" }
 /^struct ToolCallData:/ { copying=1 }
 /^    \/\/ MARK: - File ID Extraction/ { copying=0; print "}" }
 copying { print }' "$repo/$source_file" > "$scratch/Parsers.swift"
awk '/^enum ToolCallParser/ { copying=1 }
 /^    \/\/ MARK: - File ID Extraction/ { copying=0; print "}" }
 copying { sub("enum ToolCallParser", "enum ReferenceToolCallParser"); print }' "$scratch/Baseline.swift" >> "$scratch/Parsers.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    "$scratch/Parsers.swift" "$repo/Tests/ParserScans/ParserChecks.swift" -o "$scratch/tests"
"$scratch/tests" "$@"
