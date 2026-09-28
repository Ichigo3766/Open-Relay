#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
qa=$(mktemp -d "${TMPDIR:-/tmp}/relay-model-roundtrip.XXXXXX")
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$qa/ModuleCache" \
  "$repo/Open UI/Core/Models/Channel.swift" \
  "$repo/Open UI/Core/Models/KnowledgeItem.swift" \
  "$repo/Open UI/Core/Models/Prompt.swift" \
  "$repo/Open UI/Core/Models/WorkspaceModels.swift" \
  "$repo/Open UI/Core/Extensions/TimestampParser.swift" \
  "$repo/Tests/ModelRoundTrip/Checks.swift" -o "$qa/checks"
"$qa/checks"
