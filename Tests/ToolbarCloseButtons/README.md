# Native toolbar close buttons

`audit.py` guards against drawing a second circle inside a native toolbar close
button. It scans toolbar items only; inline clear/remove controls are unchanged.

```sh
python3 Tests/ToolbarCloseButtons/audit.py
```

## Synthetic visual and dismissal checks

The gallery uses the actual production sheet views. For toolbars owned by a
larger container, `prepare_gallery.py` extracts the complete production toolbar
item and replaces only its owner-state action with `dismiss()`. The separate
`testRealSidebarDismissal` test exercises the actual sidebar presentation and
dismissal callbacks for Archived Chats, Shared Chats, Notes, Automations,
Memories, Workspace, and Admin Console.

Use a disposable simulator containing **only loopback fixture servers**. The
gallery rejects saved non-loopback servers. All fixture responses are freshly
invented or empty; no real account, conversation, file, or server is needed.

```sh
python3 Tests/ToolbarCloseButtons/fixture.py
# In another terminal, choose a new directory outside the checkout:
python3 Tests/ToolbarCloseButtons/prepare_gallery.py /tmp/close-button-qa
```

Build/install the copied `Open UI` app using the normal simulator scheme. The
copy contains a test-only entry point and exposes the private prompt-history
sheet to the gallery. It also splits the large chat view expression for Xcode's
type checker. None of these harness adjustments ship in the app.

Before capturing, deny the disposable app's optional Photos permission to avoid
a first-launch prompt over the sheet:

```sh
xcrun simctl privacy SIMULATOR_ID revoke photos-add com.openui.openui
```

```sh
cd Tests/ToolbarCloseButtons
xcodegen generate
xcodebuild -project ToolbarCloseTests.xcodeproj -scheme ToolbarClose \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:ToolbarCloseUITests/ToolbarCloseUITests/testLight \
  -only-testing:ToolbarCloseUITests/ToolbarCloseUITests/testDark test
```

Run `testTabletLight` and `testTabletDark` on an iPad simulator, and
`testRealSidebarDismissal` on an iPhone. Each gallery test opens the sheet,
checks that its close control is hittable, captures an attachment, taps it, and
verifies that the gallery is accessible again. Before/after builds use the same
fixture and harness; only the production close-button changes differ.
Run one simulator test session at a time.

## Screenshot inventory

Validated against `b38bfe9` and the fix using iOS/iPadOS 27 simulators:
four source regression tests pass; 25 gallery cases in both themes open and
dismiss successfully before and after; all seven normal sidebar routes pass.
The source audit fails on the 25 decorated toolbar buttons in the baseline.

Every changed toolbar has a corresponding gallery case, captured in both themes:

| Area | Screens |
| --- | --- |
| Library | Archived Chats, Shared Chats, Notes, Automations, Memories, Workspace |
| Channels | Channels, Members, conversation settings, Pinned Messages |
| Accounts | Account picker, server switcher, connection-overlay server sheet |
| Admin | Admin Console, Edit User, user chats, integration access |
| Other | Voice settings, Voice Note, prompt version history, app update, combined update |
| iPad containers | Admin Console, Memories, Notes |

Do not publish simulator logs, result bundles, or screenshots from a real library.
