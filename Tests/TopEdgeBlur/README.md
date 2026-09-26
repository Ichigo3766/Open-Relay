# Top-edge blur visual checks

Use a disposable simulator with **only** the included synthetic account. The
fixture serves invented prose and a long blue message bubble, without contacting
any real server or model.

1. Run `python3 Tests/TopEdgeBlur/fixture.py`.
2. Build/install Open Relay, then connect it to `http://127.0.0.1:18191` using
   the Advanced API-key option and the dummy key `synthetic-token`.
3. With XcodeGen installed, run:

   ```sh
   cd Tests/TopEdgeBlur
   xcodegen generate
   xcodebuild -project TopEdgeBlurTests.xcodeproj -scheme TopEdgeBlur \
     -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
     -derivedDataPath DerivedData -parallel-testing-enabled NO test
   ```

The checks launch both appearances with the transparent toolbar enabled, scroll
prose and colored content beneath the status area, return from the background,
reverse scrolling, and open the keyboard. Screenshot attachments capture several
positions for visual review. The gestures target an iPhone 16 Pro-sized simulator.

Run the same sequence on baseline `b38bfe9` and the changed build. Compare the
`*-prose-*`, `*-color-0`, and `*-resumed` captures: there should be no light gray
wash over the dark background, the blur should stay near the status icons, and
controls/composer should be unchanged. The default native effect still adapts contrast to
the appearance. UI assertions cover interactions; they do not establish blur quality.
The older-iOS material branch and the toolbar preference are unchanged.

With Pillow installed, also run `python3 check_dark_background.py dark-color-0.png`
on the exported screenshot. It compares empty status/body gutter samples and
rejects visible background lightening. This fails on the rejected clear-glass
candidate (`04ccdd6`); inspect the actual screenshots as well as the measurement.

Also run `python3 check_status_calibration.py light-calibration.png dark-calibration.png`.
This checks the blank blue bubble for unwanted lightening and verifies its edge
is blurred near the top but sharp by the top safe area's bottom (62pt on this
simulator). Dark-mode native contrast adjustment is
allowed. The forced `.soft` candidate (`b33b62f`) fails: in light mode it lightens
the blue by 108/255, and both appearances blur the edge below the status area.
The replacement leaves the native style at its default rather than forcing `.soft`.

Share only reviewed synthetic screenshots, not raw result bundles or device logs.
