#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d "/tmp/relay-stream-tests.XXXXXX")"
swift_flags=()
baseline_ref="${RELAY_BASELINE_REF:-b38bfe91ab0d584c7ab22ac119adadae1af3dbf5}"
if [[ "${1:-}" == "--baseline" ]]; then
    git -C "$repo" show "$baseline_ref:Open UI/Core/Services/StreamingPipeline.swift" > "$scratch/Pipeline.swift"
    git -C "$repo" show "$baseline_ref:Open UI/Core/Services/StreamingContentStore.swift" | sed '/^import UIKit$/d' > "$scratch/Store.swift"
    git -C "$repo" show "$baseline_ref:Open UI/Features/Chat/ViewModels/ChatViewModel.swift" |
        sed -n '/^final class ContentAccumulator:/,$p' > "$scratch/AccumulatorBody.swift"
    swift_flags+=(-D BASELINE)
else
    cp "$repo/Open UI/Core/Services/StreamingPipeline.swift" "$scratch/Pipeline.swift"
    cp "$repo/Open UI/Core/Services/StreamingContentStore.swift" "$scratch/Store.swift"
    sed -n '/^final class ContentAccumulator:/,$p' "$repo/Open UI/Features/Chat/ViewModels/ChatViewModel.swift" > "$scratch/AccumulatorBody.swift"
fi
printf 'import Foundation\n' > "$scratch/Accumulator.swift"
cat "$scratch/AccumulatorBody.swift" >> "$scratch/Accumulator.swift"
# Compile the actual pure reconstruction helpers, not a mock implementation.
awk 'BEGIN { print "import Foundation\nnonisolated enum MessageHistory {" }
 /^    static func reconstructContentFromOutput/ { copying=1 }
 /^    \/\/ MARK: - Human-in-the-Loop/ { copying=0 }
 /^    private static func htmlEntityEncode/ { copying=1 }
 /^    \/\/\/ Parses a single node/ { copying=0 }
 copying { print }
 END { print "}" }' "$repo/Open UI/Core/Models/MessageHistory.swift" > "$scratch/Output.swift"
if [[ -n "${RELAY_SWIFT_FLAGS_FILE:-}" ]]; then
    while IFS= read -r flag; do swift_flags+=("$flag"); done < "$RELAY_SWIFT_FLAGS_FILE"
fi
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    ${swift_flags[@]+"${swift_flags[@]}"} "$scratch/Pipeline.swift" "$scratch/Store.swift" \
    "$scratch/Accumulator.swift" "$scratch/Output.swift" "$repo/Tests/ImmediateStreaming/TestSupport.swift" \
    "$repo/Tests/ImmediateStreaming/ResponseTests.swift" \
    "$repo/Tests/ImmediateStreaming/StreamingTests.swift" -o "$scratch/tests"
"$scratch/tests"
echo "Artifacts: $scratch"
