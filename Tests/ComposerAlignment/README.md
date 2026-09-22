# Two-row composer

The empty composer uses one compact row while the keyboard is hidden. With
the keyboard visible or a nonempty draft, text gets its own full-width row,
with attachment, dictation, and send/voice controls below. Previously, the controls
reserved columns on either side of the text and moved vertically as drafts grew.
This suite measures the actual app's text and button positions.

All accounts, conversation text, and drafts are invented. The loopback fixture
rejects message generation, chat writes, and configuration updates. Run only
on a disposable simulator containing this fixture account; XCTest screenshots
must never be collected from a personal account.

## Coverage

- Four-line drafts in light and dark appearances.
- Long text that wraps naturally without explicit newlines.
- A 14-line draft that scrolls internally without moving the controls.
- Expanded composition, with controls remaining below the text at the bottom.
- Empty and single-line inputs, including the voice-to-send transition.
- Empty keyboard-hidden/visible states, repeated focus/dismissal, and clearing
  the last character without losing keyboard focus.
- Nonempty drafts keep their full-width layout when the keyboard is dismissed.
- Single-line input in both appearances, plus minimum/maximum UI control sizes.
- A whitespace-only multiline draft, which keeps the voice button visible.
- Fixture content, authentication, and rejected write requests.

The original layout from upstream commit
`a5c0cfa014c92b4875b7ccb2a64562205b258eb8` (v5.7.1) was reproduced on iOS 18
and iOS 26. Bottom-aligning that inline row alone still fails the full-width
regression: the text remains inset past the plus button's column.
Two-row checks require text to span the controls' visible width and stay above every button.
The bare plus glyph has an optical leading adjustment to match the trailing
circle's visible edge: both sit approximately 12 points from the composer edge
instead of 20 points for the plus and 12 for send. Symmetry assertions allow
one point for glyph metrics and pixel rounding, including at UI scales 0.85–1.3.
On iOS 18, accessibility exposes the glyph rather than the full clear circular
button. Assertions use its center and the control's declared diameter (28 points
for plus, 26 for the trailing controls) at the default UI scale on both OS versions.

## Run

Requires Xcode, XcodeGen, Python 3, and a disposable iOS simulator with the
normal Open Relay app installed. No production server is needed.

```sh
python3 -m unittest discover -s Tests/ComposerAlignment -p 'test_*.py' -v
python3 Tests/ComposerAlignment/mock_server.py
```

The fixture defaults to `http://127.0.0.1:18087`. The UI test can sign in using
`demo@example.test` / `synthetic`, or reuse an existing fixture-only sign-in.
The optional `--port` server argument supports another loopback port.

```sh
xcodegen generate --spec Tests/ComposerAlignment/project.yml
xcodebuild -project Tests/ComposerAlignment/ComposerTests.xcodeproj \
  -scheme ComposerTests \
  -destination 'platform=iOS Simulator,id=SYNTHETIC_SIMULATOR_UUID' \
  -derivedDataPath /tmp/relay-composer-test-build \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/relay-composer-results.xcresult test
```

Tests use launch arguments to select appearance and allow Return to insert
newlines. They do not press Send or start microphone recording.

## Screenshots

Every screenshot uses the invented fixture conversation and draft above.

| Appearance | Before | After |
| --- | --- | --- |
| iOS 26, light | [Before](Screenshots/before-ios26-light.png) | [After](Screenshots/after-ios26-light.png) |
| iOS 26, dark | [Before](Screenshots/before-ios26-dark.png) | [After](Screenshots/after-ios26-dark.png) |
| iOS 18, light | [Before](Screenshots/before-ios18-light.png) | [After](Screenshots/after-ios18-light.png) |
| iOS 18, dark | [Before](Screenshots/before-ios18-dark.png) | [After](Screenshots/after-ios18-dark.png) |

### Empty composer

| Version | Keyboard hidden: one row | Keyboard visible: two rows |
| --- | --- | --- |
| iOS 26 | [Hidden](Screenshots/after-ios26-empty.png) | [Visible](Screenshots/after-ios26-empty-keyboard.png) |
| iOS 18 | [Hidden](Screenshots/after-ios18-empty.png) | [Visible](Screenshots/after-ios18-empty-keyboard.png) |

### Single-line drafts

| Appearance | Screenshot |
| --- | --- |
| iOS 26, light | [Single line](Screenshots/after-ios26-single-line-light.png) |
| iOS 26, dark | [Single line](Screenshots/after-ios26-single-line-dark.png) |
| iOS 18, light | [Single line](Screenshots/after-ios18-single-line-light.png) |
| iOS 18, dark | [Single line](Screenshots/after-ios18-single-line-dark.png) |
