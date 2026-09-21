# Message action preferences checks

Run from the repository root on macOS (no app, network, or external packages needed):

```sh
test_output=$(mktemp -d)
swiftc "Open UI/Core/Models/MessageActionPreferences.swift" Tests/MessageActionPreferences/main.swift -o "$test_output/checks"
"$test_output/checks"
```

Checks defaults, legacy settings, unknown/duplicate IDs, JSON persistence, editing and deletion, reset, and keeping an active speech control available. Includes 200 deterministic randomized cases for mixed ordering, visibility, deletion, and reordering only the server-allowed subset. URL cases include reserved punctuation, newlines, Unicode, and long text. A temporary UserDefaults suite is removed after the test.

For UI checks, use a fresh disposable simulator with the normal app build and this loopback-only fixture:

```sh
python3 Tests/MessageActionPreferences/mock_server.py
```

Connect to `http://127.0.0.1:18083` with `demo@example.test` / `synthetic`. The fixture never contacts or imports Open WebUI and stores everything in memory. Open the invented conversation from the sidebar or `openui://chat/b7185907-9171-4c49-ab9d-d5a12d201237`.

- In Settings → Chat Behavior → Message Actions, add, rename, change the icon, hide/show, reorder, and delete a custom action from its editor. Blank or whitespace-only names must keep Save disabled; Cancel must discard edits.
- Create a real Apple Shortcut with a `Copy to Clipboard` action whose value is `Shortcut Input`. Give it exactly the name entered in Open Relay, including punctuation. Tap the actual message button and compare `xcrun simctl pbpaste SIMULATOR_UUID` with the expected cleaned text and source links. Check both response versions and a long message. Apple's own Shortcut permissions may appear on first use.
- Ensure a crowded toolbar wraps and all buttons remain visible, tappable, and exposed as accessibility actions. Check smaller screens and dark mode.
- Relaunch and verify order, visibility, and edited fields persist. Reset must restore visibility/order and retain the custom actions.
- `POST /fixture` accepts `permissions`, `rating_enabled`, `text`, and `versions`. Change the simulated server permissions, then sign in again to refresh them. Disallowed built-ins must be absent from both settings and chat. Reordering the remaining items must preserve the omitted items' saved positions. Disabling `rating_enabled` must omit thumbs-up/down even when the account allows ratings.
- `GET /fixture` exposes app writes; `POST /fixture` clears that trace. Local action changes must not cause settings writes or place custom action fields in any request. Normal sign-in and chat-version updates are separate from local action settings.

The URL contract follows [Apple's Shortcuts URL scheme documentation](https://support.apple.com/guide/shortcuts/apd624386f42/ios). Version navigation and model-provided actions remain outside the local preference list.
