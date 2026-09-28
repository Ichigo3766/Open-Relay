#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
qa=$(mktemp -d "${TMPDIR:-/tmp}/relay-calendar-color.XXXXXX")
xcrun swiftc -parse-as-library -default-isolation MainActor \
  -module-cache-path "$qa/ModuleCache" \
  "$repo/Open UI/Core/Models/CalendarModels.swift" \
  "$repo/Open UI/Shared/Theme/ColorTokens.swift" \
  "$repo/Tests/CalendarColor/Checks.swift" -o "$qa/checks"
"$qa/checks"
