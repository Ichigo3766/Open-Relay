#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:?Set TMPDIR to external test storage}/relay-parse-cache.XXXXXX")
source_file='Open UI/Shared/Components/ToolCallView.swift'
variant=${1:-candidate}
shift || true
if [ "$variant" = baseline ]; then
    git show "f5b8ce858cd790718a31107d954e6cfe32704bb2:$source_file" > "$scratch/Source.swift"
else
    cp "$repo/$source_file" "$scratch/Source.swift"
fi
awk 'BEGIN { print "import Foundation\nimport os" }
 /^actor MessageParseCache/ { copying=1 }
 /^    \/\/ MARK: - File ID Extraction/ { copying=0; print "}" }
 copying { print }' "$scratch/Source.swift" > "$scratch/Cache.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    "$scratch/Cache.swift" "$repo/Tests/ParseCacheBudget/CacheChecks.swift" -o "$scratch/tests"
"$scratch/tests" "$@"
