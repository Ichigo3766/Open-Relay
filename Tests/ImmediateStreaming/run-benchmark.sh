#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d /tmp/relay-stream-benchmark.XXXXXX)"
if [[ "${1:-}" == "--baseline" ]]; then
    git -C "$repo" show "${RELAY_BASELINE_REF:-b38bfe91ab0d584c7ab22ac119adadae1af3dbf5}:Open UI/Core/Services/StreamingPipeline.swift" > "$scratch/Pipeline.swift"
else
    cp "$repo/Open UI/Core/Services/StreamingPipeline.swift" "$scratch/Pipeline.swift"
fi
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$scratch/Pipeline.swift" "$repo/Tests/ImmediateStreaming/Benchmark.swift" -o "$scratch/benchmark"
"$scratch/benchmark"
echo "Artifacts: $scratch"
