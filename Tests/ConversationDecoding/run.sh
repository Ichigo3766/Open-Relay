#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:?Set TMPDIR to disposable test storage}/relay-decoding.XXXXXX")
variant=${1:-candidate}
shift || true
flags=(-D CANDIDATE)
for name in Cache API; do
    if [ "$name" = Cache ]; then source_file='Open UI/Core/Services/ConversationCache.swift'
    else source_file='Open UI/Core/Networking/APIClient.swift'; fi
    if [ "$variant" = baseline ]; then
        git show "f5b8ce858cd790718a31107d954e6cfe32704bb2:$source_file" > "$scratch/$name-source.swift"
        flags=(-D BASELINE)
    else cp "$repo/$source_file" "$scratch/$name-source.swift"; fi
done
# Only singleton storage and the JSON call counter are injected. All validation,
# freshness, invalidation, and response handling are the selected production code.
sed -e 's/static let shared = ConversationCache()/static let shared = ConversationCache(directory: testDirectory, defaults: testDefaults)/' \
    -e 's/JSONSerialization.jsonObject(with:/DecodeProbe.jsonObject(with:/g' \
    "$scratch/Cache-source.swift" > "$scratch/Cache.swift"
awk 'BEGIN { print "import Foundation\nextension APIClient {" }
 /^    func cachedConversation\(id:/ { copying=1 }
 copying && /^    \/\/\/ Creates a new permanent chat/ { print "}"; exit }
 copying { gsub("JSONSerialization.jsonObject", "DecodeProbe.jsonObject"); print }' \
    "$scratch/API-source.swift" > "$scratch/API.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library "${flags[@]}" -module-cache-path "$scratch/ModuleCache" \
    "$scratch/Cache.swift" "$scratch/API.swift" "$repo/Open UI/Core/Networking/APIError.swift" \
    "$repo/Tests/ConversationDecoding/Checks.swift" -o "$scratch/tests"
"$scratch/tests" "$scratch" "$@"
