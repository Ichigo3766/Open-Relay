#!/bin/bash
# Component tests: real parsing/splitting, stubbed UIKit rendering, native SwiftUI identities.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
package="${MARKDOWN_VIEW_SOURCE:?Set MARKDOWN_VIEW_SOURCE to the pinned MarkdownView checkout}"
cmark="${CMARK_SOURCE:?Set CMARK_SOURCE to its swift-cmark checkout}"
scratch="$(mktemp -d /tmp/relay-render-tests.XXXXXX)"
flags=()
if [[ -n "${RELAY_SWIFT_FLAGS_FILE:-}" ]]; then
    while IFS= read -r flag; do flags+=("$flag"); done < "$RELAY_SWIFT_FLAGS_FILE"
fi
clang -O2 -dynamiclib -I"$cmark/src/include" -I"$cmark/extensions/include" \
    -I"$cmark/src" -I"$cmark/extensions" "$cmark"/src/*.c "$cmark"/extensions/*.c \
    -o "$scratch/libcmark-local.dylib"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files --no-ignore "$package/Sources/MarkdownParser" -g '*.swift')
swiftc -O -swift-version 5 -parse-as-library -emit-module -emit-library -module-name MarkdownParser \
    -target arm64-apple-macosx14.0 "${flags[@]}" \
    -I"$cmark/src/include" -I"$cmark/extensions/include" -L"$scratch" -lcmark-local \
    "${sources[@]}" -emit-module-path "$scratch/MarkdownParser.swiftmodule" -o "$scratch/libMarkdownParser.dylib"
source="$repo/Open UI/Shared/Components/StreamingMarkdownView.swift"
printf 'import SwiftUI\nimport MarkdownParser\n' > "$scratch/Renderer.swift"
sed -n '/^private struct StableStreamingMarkdown:/,$p' "$source" |
    sed 's/^private struct StableStreamingMarkdown:/struct StableStreamingMarkdown:/' >> "$scratch/Renderer.swift"
printf 'import Foundation\nstruct SegmentParsingHarness {\nlet isStreaming: Bool\n' > "$scratch/Segments.swift"
sed -n '/^    private let chartLanguageTags:/,/^    private let pythonLanguageTags:/p' "$source" >> "$scratch/Segments.swift"
sed -n '/^    private struct ContentSegment:/,/^    \/\/ MARK: - Markdown Image Regex Patterns/p' "$source" |
    sed 's/private struct ContentSegment/struct ContentSegment/' >> "$scratch/Segments.swift"
sed -n '/^    private static func parseFenceLine/,/^    private func looksLikeSVG/p' "$source" |
    sed '$d' >> "$scratch/Segments.swift"
sed -n '/^    private func looksLikeSVG/,/^    }/p' "$source" >> "$scratch/Segments.swift"
printf 'func segments(_ text: String) -> [ContentSegment] { parseCodeBlocks(text) }\n}\n' >> "$scratch/Segments.swift"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    "${flags[@]}" -I"$scratch" -L"$scratch" -lMarkdownParser -lcmark-local \
    -Xlinker -rpath -Xlinker "$scratch" \
    -I"$cmark/src/include" -I"$cmark/extensions/include" \
    "$scratch/Renderer.swift" "$scratch/Segments.swift" \
    "$repo/Tests/ImmediateStreaming/RendererStubs.swift" "$repo/Tests/ImmediateStreaming/RendererTests.swift" \
    "$package/Sources/MarkdownView/MarkdownTextBuilder/PreprocessedContent+Split.swift" \
    "$package/Sources/MarkdownView/MarkdownTextBuilder/IncrementalStreamingParser.swift" \
    -o "$scratch/tests"
"$scratch/tests"
echo "Artifacts: $scratch"
