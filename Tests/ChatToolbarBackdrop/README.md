# Floating chat toolbar regression

On iOS 26, the top controls must retain their individual glass backgrounds without
a full-width material band obscuring the response behind them. Earlier iOS versions
must retain their existing material band. The separate status-bar safe-area blur
must remain on both, including when the controls hide.

Run the structural checks (Python standard library only):

```sh
python3 -m unittest discover -s Tests/ChatToolbarBackdrop -p 'test_*.py' -v
```

`test_full_width_backdrop_is_only_for_legacy_ios` fails on upstream commit
`a5c0cfa014c92b4875b7ccb2a64562205b258eb8`. The other guards preserve the legacy
backdrop, status-bar blur, and individual control glass. These are source-level guards,
not pixel-level visual assertions.

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
menu interaction, and capture light/dark screenshots for visual inspection.
Compare screenshots before and after the fix: on iOS 26, text between the floating
controls should remain clear, while text under the status icons should still be
softened. On iOS 18, the full-width toolbar backdrop should be unchanged.

## Verified

- Baseline and corrected Release simulator builds passed.
- The version-gating regression fails on the baseline; all four structural checks
  pass with the fix.
- Both light/dark UI tests passed on iPhone 17 Pro / iOS 26.5 and iPhone SE
  (3rd generation) / iOS 18.4, before and after the fix.
- Before/after screenshots in `Screenshots/` were visually reviewed: iOS 26 loses
  the full-width band, while iOS 18 retains it. Status-icon blur remains present.
  All screenshot content comes from the invented fixture above, not a real account.

These checks cover simulator rendering and toolbar interaction, not physical-device
performance or every accessibility display setting.
