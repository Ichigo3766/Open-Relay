# Message action preferences checks

Run from the repository root on macOS (no app, network, or external packages needed):

```sh
output=$(mktemp -d)
swiftc "Open UI/Core/Models/MessageActionPreferences.swift" Tests/MessageActionPreferences/main.swift -o "$output/checks"
"$output/checks"
rm -rf "$output"
```

Checks defaults, hidden actions, saved ordering, unknown/duplicate IDs, storage round-trips, reset, and keeping the speech stop action available. A temporary UserDefaults suite is removed after the test.

UI validation: open Settings → Chat Behavior → Message Actions; hide Speak, move Share above Copy, leave Settings, and inspect a saved assistant response. Relaunch and verify the preference persists. Reset to Defaults and verify the original built-in buttons return. Server permissions and per-message availability must still be respected. Version navigation and model-provided actions are not configurable.
