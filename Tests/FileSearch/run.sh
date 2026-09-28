#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
qa=$(mktemp -d "${TMPDIR:-/tmp}/relay-file-search.XXXXXX")
xcrun swiftc -parse-as-library -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$qa/ModuleCache" \
  "$repo/Open UI/Features/Chat/ViewModels/LibrarySearchModel.swift" \
  "$repo/Open UI/Core/Networking/APIClient+LibrarySearch.swift" \
  "$repo/Open UI/Core/Networking/APIError.swift" \
  "$repo/Tests/FileSearch/Checks.swift" -o "$qa/checks"
"$qa/checks"
