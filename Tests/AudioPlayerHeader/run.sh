#!/bin/bash
# Extract the production visibility predicate; do not maintain a duplicate implementation.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
source_file="$repo/Open UI/Features/Chat/Views/ChatDetailView.swift"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/audio-header-tests.XXXXXX")
rg -q 'private var showsReadAloudPlayer: Bool' "$source_file"
awk '/\.chatChromeBar\(edge: \.top\)/ { header = 1 }
     /\.chatChromeBar\(edge: \.bottom\)/ { header = 0 }
     header && /readAloudPlayerBar/ { found = 1 }
     END { exit !found }' "$source_file"
rg -q 'if showsReadAloudPlayer \{' "$source_file"
! rg -q 'if !showsReadAloudPlayer \{' "$source_file"
awk 'BEGIN {
    print "struct HeaderState {"
    print "var dependencies = Dependencies()"
    print "var speakingMessageId: String?"
    print "var ttsGeneratingMessageId: String?"
}
/private var showsReadAloudPlayer: Bool/ { copying = 1 }
copying { sub("private var", "var"); print }
copying && /^    }/ { copying = 0 }
END { print "}" }' "$source_file" > "$scratch/HeaderState.swift"
xcrun swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$scratch/ModuleCache" \
    "$scratch/HeaderState.swift" "$repo/Tests/AudioPlayerHeader/VisibilityTests.swift" \
    -o "$scratch/tests"
"$scratch/tests"
