#!/bin/bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:?Set TMPDIR to external test storage}/composer-coordinator.XXXXXX")
source_file='Open UI/Shared/Components/PasteableTextView.swift'
if [ "${1:-candidate}" = baseline ]; then
    git show "f5b8ce858cd790718a31107d954e6cfe32704bb2:$source_file" > "$scratch/Source.swift"
else
    cp "$repo/$source_file" "$scratch/Source.swift"
fi
awk 'BEGIN { print "import Foundation\nextension PasteableTextView {" }
 /^    final class Coordinator:/ { copying=1 }
 copying && /^        func textViewDidBeginEditing/ { print "    }\n}"; exit }
 copying { print }' "$scratch/Source.swift" > "$scratch/Coordinator.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    "$repo/Open UI/Shared/Components/ComposerToken.swift" "$scratch/Coordinator.swift" \
    "$repo/Tests/ComposerToken/CoordinatorChecks.swift" -o "$scratch/checks"
"$scratch/checks"
