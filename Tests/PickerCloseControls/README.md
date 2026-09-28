# Custom picker close controls

The model selector and the channel attachment picker use custom headers rather
than navigation toolbars. They now share a native icon-only Close button, with
system glass on iOS 26+ and a system bordered fallback on earlier versions.
The model selector uses the system drag indicator instead of drawing its own
grabber through the centered title.
Dismissal callbacks, selection/search behavior, attachment permissions, and file
handling are unchanged. No custom circles, blur, or glass effects are drawn.

## Source checks

```sh
python3 Tests/PickerCloseControls/audit.py
```

The checks cover both header regressions against Open Relay 6.0 (`4151a735`),
the retained callbacks, accessibility label, native appearance, and OS fallback.

## Real-app simulator checks

Use an isolated simulator with only the loopback fixture. Start `python3
Tests/PickerCloseControls/fixture.py`, add `http://127.0.0.1:18191` to the app, and
sign in using invented values. The fixture contains one demo model, an empty demo
channel, no conversations, and no media. Deny Photos access so recent real photos
cannot appear in the attachment picker; do not run this against a real library.

Build/install the normal app, then generate and run the UI test project:

```sh
cd Tests/PickerCloseControls
xcodegen generate
xcodebuild -project PickerCloseControls.xcodeproj -scheme PickerCloseControls \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath /path/to/test-output \
  -resultBundlePath /path/to/results.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Both theme cases open and dismiss the model picker, search/select the demo model,
then open/dismiss the channel attachment picker. They capture both headers for
before/after comparison. Only reviewed screenshots belong in `Screenshots/`;
never commit result bundles, logs, or a real photo library.

## Verified results

- Four source checks pass; Release simulator build passes.
- Both theme flows pass before and after on iOS 26.5. The after-only touch test
  also passes: Close dismisses at offsets of 22 points from its center in all
  four directions, not just when tapping the icon itself.
- Eight actual before/after screenshots were visually and metadata reviewed.
- Earlier-OS fallback is compiled and source-checked, not runtime-tested here.

For baseline captures, run only `testLight` and `testDark`; the Close-specific
touch test intentionally requires the updated implementation.
