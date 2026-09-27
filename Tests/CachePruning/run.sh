#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:?Set TMPDIR to disposable test storage}/relay-cache-pruning.XXXXXX")
variant=${1:-candidate}
mode=${2:-checks}
source_file='Open UI/Core/Services/ConversationCache.swift'
case "$variant" in
    baseline) git show "f5b8ce858cd790718a31107d954e6cfe32704bb2:$source_file" > "$scratch/ConversationCache.swift" ;;
    candidate) cp "$repo/$source_file" "$scratch/ConversationCache.swift" ;;
    *) exit 2 ;;
esac
case "$mode" in
    checks) test_file=CacheChecks ;;
    benchmark) test_file=CacheBench ;;
    *) exit 2 ;;
esac
xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    "$scratch/ConversationCache.swift" "$repo/Open UI/Core/Networking/APIError.swift" \
    "$repo/Tests/CachePruning/$test_file.swift" -o "$scratch/test"
"$scratch/test" "$scratch"
