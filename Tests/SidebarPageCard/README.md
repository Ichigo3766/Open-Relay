# Sidebar page-card regression

The fixture serves two freshly invented, completed chats on loopback only. It
does not contact an Open WebUI instance, generate responses, or persist data.
Use an isolated simulator with no existing account.

The page-card presentation uses the system's `ConcentricRectangle` on iOS 26+
to match the containing screen/window, without device-specific corner values.
Earlier iOS versions retain their existing sidebar presentation. Run these
visual regression tests on iOS 26 or later.

In dark mode on iOS 26+, the sidebar and footer use the existing surface color
(`#121212` by default) to separate them subtly from the chat page. Light-mode
and earlier-iOS sidebar backgrounds are unchanged. `testDarkSidebarBackground`
checks the actual rendered color in both the sidebar and footer.
It fails on the previous background (RGB 10) and passes on the updated sidebar
and footer (RGB 18). The final Release build and both theme interaction tests pass.

The mask includes the horizontal safe area while the page's controls retain
their existing insets. This prevents the screen-sized corner from cutting into
the menu button in landscape.

The page-card layout omits the sidebar's old full-height trailing divider.
Earlier-iOS drawers, the pinned iPad sidebar, and the separate landscape terminal
layout retain their dividers. The light/dark tests compare pixels at both exposed
rounded corners against the adjacent sidebar surface to catch a straight border
extending beyond the card. These assertions fail on the initial page-card build
(maximum RGB contrast: 21 in light mode, 14 in dark mode) and pass after removing
the divider (at most 2 at both corners in both themes).

The card has a low-contrast outline drawn with the same system-rounded shape as
its mask: one physical pixel (`1 / displayScale`), white at 10% in dark mode or
black at 8% in light mode. It fades with the sidebar opening fraction, ignores
hit testing, and is absent when closed. The pixel checks verify its subtle edge
contrast and width, while still rejecting a straight divider in the corner cutouts.
The outline-presence assertion fails on `e975e81` (zero edge contrast in both
themes); both theme tests and the dark-background check pass with the outline.

Install the app build under test in that simulator, then run:

```sh
python3 Tests/SidebarPageCard/fixture.py
```

In another terminal (requires XcodeGen):

```sh
cd Tests/SidebarPageCard
xcodegen generate
xcodebuild -project SidebarQA.xcodeproj -scheme UI -configuration Release \
  -destination 'platform=iOS Simulator,id=YOUR_TEST_SIMULATOR_ID' \
  -derivedDataPath /tmp/sidebar-test-products \
  -resultBundlePath /tmp/sidebar-test-results.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never -jobs 2 test
```

The light/dark tests capture closed/open states, compare the same text strip
after translation (detecting blur, dimming, scaling, or vertical movement),
exercise tap dismissal, repeat edge-open/swipe-close three times, select another
chat, focus the composer, dismiss the keyboard by opening the sidebar, and rotate
to landscape. The iPad-only test also checks that the pinned
sidebar stays visible when selecting a chat and can still be toggled. Screenshots
contain only the invented fixture data.

Review the screenshots for rounded corners, shadow, full-height coverage, and
unclipped controls in both closed/open landscape states;
the pixel assertion tests text preservation, not subjective appearance.

The menu checks after chat restoration verify that tapping actually opens and
closes the sidebar. The safe-area toolbar can report an invalid accessibility
hit point even when the control is visible and responds correctly.

## Validation

Baseline: `b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`. Release build and
focused iPhone 16 Pro UI tests used Xcode 27 (27A266a), iOS 27. The two theme
tests passed; the iPad-only check was skipped. No device-model corner constants
or additional simulator matrix are needed for the system-resolved shape.

Mean absolute RGB difference for the translated text strip (0–255 scale):

| Theme | Baseline | Page card |
| --- | ---: | ---: |
| Light | 66.29 | 0.00 |
| Dark | 41.08 | 0.00 |

The baseline fails the text-preservation assertion. The updated view passes it,
tap dismissal, three edge-open/swipe-close cycles per theme, switching chats,
keyboard dismissal, and landscape opening/dismissal. Closed/open screenshots
confirm that the menu remains unclipped in landscape. Transition frames were
also reviewed locally.
These are rendering-correctness checks, not device FPS measurements.

For the separate repeated CPU/memory benchmark and video-capture methodology,
see [PERFORMANCE.md](PERFORMANCE.md).

Xcode 27 required splitting the existing large `ChatDetailView.body` expression
into two computed views in the disposable build checkout. The same compiler-only
split was used for baseline and candidate; it is not part of this change.

## Content-swipe regression

The opening gesture no longer needs an invisible edge strip. A native,
single-finger pan takes over only when its initial rightward velocity is more
than 1.5 times its vertical velocity. UIKit supplies the movement threshold;
there is no long-press delay or added timer. Once accepted, translation in window
coordinates follows the finger without feeding the moving page's offset back
into the gesture. Existing release thresholds and animations are unchanged.
It cooperates with the chat's simultaneous drag observer rather than letting
that observer cancel an accepted sidebar pan.

The recognizer rejects controls, editable/selected text, and horizontal scrollers.
Selection is checked again when recognition begins, so a long press that selects
text before movement keeps ownership. Cancellation closes the partial drawer.
The pinned iPad sidebar and file-browser gestures are unchanged.

`testContentSwipeOpensSidebar` starts at 35% of the screen width over a message.
It fails on the edge-only build (`c525121`). The other app tests cover ordinary
scrolling, small movements, composer editing, selection, and the existing edge
and menu gestures. `testContentSwipeVideo` records the same synthetic drag on
either build without assuming that the older build opens the sidebar.

The focused `Gestures` scheme checks direction, controls, UIKit/Litext selection,
selection beginning after touch-down, and nested horizontal scrolling. The
`GestureHarness` scheme exercises the production recognizer in real SwiftUI
scroll views with the chat's low-threshold simultaneous drag observer, including
a held-then-dragged touch. This small test app uses only
invented text and never connects to a server.

The comparison recording uses actual simulator touches: one continuous
reveal/reverse/cancel gesture, a slow opening, a closing drag with a reversal,
and a flick. A recording-only overlay marks real touch events; it is not in the
app or this test project. Both panes play at their recorded speed, aligned at
the first touch, with a final-frame hold. This is a behavior demonstration, not
an FPS or latency measurement.

Validation on the same iPhone 16 Pro / iOS 27 simulator: Release build, all five
focused gesture tests, all three harness tests, six full-app interaction/rendering
tests, and four metric-parser tests passed. The full-app tests ran without the
recording overlay. Light/dark text-strip pixel differences remained zero. The
compiler-only extraction documented above also applies to this build; no iPad
or physical-device interaction run is claimed.

```sh
cd Tests/SidebarPageCard
xcodegen generate
xcodebuild test -project SidebarQA.xcodeproj -scheme Gestures \
  -destination 'platform=iOS Simulator,id=YOUR_TEST_SIMULATOR_ID'
xcodebuild test -project SidebarQA.xcodeproj -scheme GestureHarness \
  -destination 'platform=iOS Simulator,id=YOUR_TEST_SIMULATOR_ID' \
  -parallel-testing-enabled NO
```
