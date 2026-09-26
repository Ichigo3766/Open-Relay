# Voice-mode button setting

The setting is local to the device, defaults to visible, and gates only the
voice-call callback supplied to the existing composer. With voice unavailable,
the send button stays visible in a muted, disabled state until there is sendable
content. Dictation, attachments, stop behavior, and server permissions remain
independent.

## Validation

Run `python3 Tests/VoiceModeButton/audit.py` for source guards. Passing a Git
reference checks the baseline instead; `b38bfe9` lacks the preference/fallback
and fails the three new guards.

For interactive tests, use a disposable simulator with no real accounts:

1. Start `python3 Tests/VoiceModeButton/fixture.py` (loopback port 18196).
2. Run `python3 Tests/VoiceModeButton/prepare_qa.py /path/to/new/qa/app`.
3. Build the copied `Open UI.xcodeproj` and install the app on that simulator.
4. In this directory, run `xcodegen generate`, then build/test the generated
   `VoiceModeButton` scheme against the same simulator.

The copy uses production views, an invented Demo account, and a loopback-only
fixture. The QA root rejects non-loopback server configurations. The script's
expression split is for Xcode's type checker only; no QA code ships in the app.

The five UI tests check default-on behavior, immediate off/on updates, persistence
across relaunch, keyboard-hidden and keyboard-visible composition, quick buttons,
separate call/dictation permissions, and no server writes. Screenshots cover the
setting and enabled/disabled new-chat composer in light and dark mode.
The typing checks verify the exact draft, enabled send state, and disabled send
state after clearing or entering only whitespace. Keyboard events are entered
individually so each can settle before the next assertion.

Export and review screenshot attachments before publication. Never publish raw
logs or result bundles.

Verified with Xcode 27.0 on an iPhone 16 Pro simulator running iOS 27.0:
the simulator app build, all five UI tests, and all five source guards passed.
