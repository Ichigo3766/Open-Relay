# Floating chat toolbar regression

The full-width toolbar background is retained by default. On iOS 26, users can
enable **Settings → Appearance → Chat Appearance → Transparent Chat Toolbar**
to show conversation text between the individual glass controls. This preference
is local to the device and defaults to off. Earlier iOS versions neither show the
setting nor honor an enabled value. The separate status-bar safe-area blur remains
on both, including when the controls hide.

Run the structural checks (Python standard library only):

```sh
python3 -m unittest discover -s Tests/ChatToolbarBackdrop -p 'test_*.py' -v
```

The opt-in/default/settings guards fail before the preference is implemented.
Six checks cover the shared default-off preference, iOS 26 gating, original
material and tint, status-bar blur, and individual control glass. These are
source-level guards, not pixel-level visual assertions.

For visual verification, use a **fresh disposable simulator**, never an existing
account. The loopback fixture creates only invented content in memory and never
contacts or imports Open WebUI. Build and install the regular Open Relay app,
then start the fixture and run the UI checks with XcodeGen and Xcode:

```sh
python3 Tests/ChatToolbarBackdrop/mock_server.py
# In another terminal:
xcodegen generate --spec Tests/ChatToolbarBackdrop/project.yml
xcodebuild -project Tests/ChatToolbarBackdrop/ChatToolbarTests.xcodeproj \
  -scheme ChatToolbarTests -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/relay-toolbar-build \
  -resultBundlePath /tmp/relay-toolbar-results.xcresult \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- test
```

The UI tests sign into `http://127.0.0.1:18088` with the invented fixture account,
scroll a long answer in both directions, verify toolbar hiding/reappearance and
menu interaction, and capture light/dark screenshots with the preference off and
on. A fifth test opens Appearance, checks the initial off state, toggles it both
ways, returns to the existing chat, and verifies both values survive app relaunch.
On iOS 18 it checks that the setting is absent. Launch-argument overrides exercise
both values on iOS 18 to verify that the old background is always retained.

Review the screenshots: on iOS 26, enabling the setting removes only the toolbar
band, while the status-icon blur and individual glass controls stay visible.
Disabling it restores the original band. iOS 18 should remain unchanged.

## Verified

- Full Debug simulator app build and six structural checks pass.
- Five UI tests pass on each of iOS 26.5 and iOS 18.4: light/dark scrolling and
  controls with both preference values, plus setting availability and persistence.
- Screenshot content comes only from the invented fixture above, not a real account.
- The iOS 26 `before`/`after` images show the default and enabled states respectively.
  [Setting off](Screenshots/settings-off.png) and [setting on](Screenshots/settings-on.png)
  show the new Appearance option. The iOS 18 comparison retains the original background.

These checks cover simulator rendering and toolbar interaction, not physical-device
performance or every accessibility display setting.
