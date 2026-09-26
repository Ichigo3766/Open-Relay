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
`*-prose-*`, `*-color-0`, and `*-resumed` captures: the status-area wash should be
gone, blurred text should become clear earlier, and controls/composer should be
unchanged. UI assertions cover interactions; they do not establish blur quality.
The older-iOS material branch and the toolbar preference are unchanged.

Share only reviewed synthetic screenshots, not raw result bundles or device logs.
