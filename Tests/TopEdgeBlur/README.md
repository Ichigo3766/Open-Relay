# Status-area blur visual checks

Use a disposable iPhone 16 Pro simulator with **only** the included synthetic
account. The fixture serves invented prose and a tall blue message bubble;
it does not contact a real server or model.

1. Run `python3 Tests/TopEdgeBlur/fixture.py`.
2. Build and install Open Relay on the disposable simulator.
3. With XcodeGen installed, run:

   ```sh
   cd Tests/TopEdgeBlur
   xcodegen generate
   xcodebuild -project TopEdgeBlurTests.xcodeproj -scheme TopEdgeBlur \
     -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
     -derivedDataPath DerivedData -parallel-testing-enabled NO test
   ```

The test connects a fresh install to `http://127.0.0.1:18191` using the fixture's
invented email/password. Never run it on a simulator containing a real account.
Both appearances use the transparent toolbar. Each test resets the scroll
position, scrolls content under the status icons, hides and reveals controls,
returns from the background, opens the keyboard, and captures a blank blue
calibration bubble. UI assertions check interactions, not visual quality.

Run the same sequence on release 5.9 (`4876661`) and the changed build on
**both iOS 26 and iOS 27**. Compare the `*-color`, `*-controls-hidden`,
`*-resumed`, and `*-keyboard` attachments. Content positions must match.

## Expected behavior

- **iOS 27, built with the iOS 27 SDK or newer:** the native effect blurs content
  near the status icons without the clear-glass overlay's pale band. Content is
  sharp again near the bottom of the status safe area; toolbar and composer
  controls retain their glass styling.
- **iOS 26 or an older-SDK build:** preserve release 5.9's explicit glass backdrop.
  Using only `safeAreaInset` with the navigation bar hidden produces **no status
  blur** on iOS 26. An SDK-26 compatibility probe on iOS 27 also loses the native
  effect. Removing the tint by also removing blur is not a valid fix. Missing
  SDK metadata falls back to the existing backdrop.
- **Earlier iOS:** the existing material fallback is unchanged.

## App build configuration

Compare both revisions with the same Xcode and Release build settings. The
captures use Xcode 27 and the iOS 27 SDK, not an App Store binary. Pass
`-xcconfig Tests/TopEdgeBlur/build.xcconfig` when building the app for these tests.
The test-only configuration raises the existing large view's type-checking
limits and lets the linker strip unused functions from the pinned collections
package. Without the latter, its unused `_borrow` function imports
`_swift_initBorrow`, which is absent from the iOS 26 simulator runtime.
These settings are identical for the baseline and changed app; they are not
applied to normal app builds and do not change package sources or versions.

The SDK-26 compatibility probe changes a copy of the built app's Mach-O SDK
version with `vtool` and its `DTSDKName`, then re-signs that disposable copy.
This exercises the linked-on-or-after behavior and fallback selection; it is
not a build made with an older Xcode. Never modify the comparison originals.

## Pixel checks

Export PNG attachments with `xcresulttool export attachments`. With Pillow
installed, run these checks on the changed iOS 27 captures:

```sh
python3 check_dark_background.py dark-color.png
python3 check_status_calibration.py light-calibration.png dark-calibration.png
```

The blank bubble isolates background lightening from text. The calibration check
requires blur near the top and a sharp edge at the safe area's bottom (62pt on
this 3x simulator). It permits native dark-mode contrast adjustment, but rejects
lightening over 10/255. The background check samples the empty dark gutter.
Inspect the screenshots too; these measurements do not establish overall
perceptual quality.

For iOS 26, use `check_status_calibration.py --legacy` to check blur extent while
allowing the unchanged released tint. Compare baseline and changed captures;
do not apply the iOS 27 no-lightening expectation to this fallback.

Share only reviewed synthetic PNGs, stripped of metadata without changing their
pixels. Do not share raw result bundles, simulator logs, or account state.
