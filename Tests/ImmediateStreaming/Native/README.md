# Native streaming QA

Use a disposable simulator with no real accounts. All content here is freshly
invented. The server binds only to loopback, keeps chats in memory, and never
imports or contacts Open WebUI. Do not point this harness at a real instance.
Keep raw Xcode logs/results/videos outside version control: they can contain
host paths even though the test content is synthetic.

Requires Xcode, an installed compatible simulator runtime, XcodeGen, and Python
with `aiohttp` and `python-socketio` in an isolated environment.

From this directory, generate the test project:

    export RELAY_CHECKOUT="$(git rev-parse --show-toplevel)"
    xcodegen generate
    mkdir -p RelayStreamingQA.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    cp "$RELAY_CHECKOUT/Open UI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
      RelayStreamingQA.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

Set `RELAY_DEVICE` to the disposable simulator UUID and `RELAY_BUILD` to a scratch
build directory. Build the real optimized application and hosted tests:

    xcodebuild -project RelayStreamingQA.xcodeproj -scheme Native \
      -configuration Release -destination "platform=iOS Simulator,id=$RELAY_DEVICE" \
      -derivedDataPath "$RELAY_BUILD" -xcconfig compiler.xcconfig \
      -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES build-for-testing

Use `test-without-building` with the resulting `.xctestrun` file. Run serially
(`-parallel-testing-enabled NO`), with no simultaneous builds or video recording
for timing runs. Repeat baseline and candidate runs on the same warmed simulator.
Use `-collect-test-diagnostics never` if simulator diagnostic collection stalls
after tests; assertion results and normal test attachments are still retained.
To build the original implementation, use an isolated checkout of the baseline,
set `RELAY_CHECKOUT` to it, regenerate, and add
`RELAY_QA_NativeTests=-D QA_BASELINE`. This reports known streaming defects without
requiring the baseline to satisfy the new view-identity assertions.

For end-to-end UI tests, start `python fixture.py`, build scheme `UI`, and run its
`.xctestrun` after installing the desired app build. The tests configure the
loopback server on a fresh device and require the synthetic model label before
sending anything. They exercise slow thinking, long prose/code, formatting,
scrolling, expansion/collapse, cancellation, and subsequent new responses.
The thinking disclosure is hidden inside a combined accessibility element, so
that test uses a default-font-scale fixture coordinate and verifies the resulting
expanded/collapsed heights. Do not use that coordinate with arbitrary content.

The compiler configuration only raises expression-checking limits for the app
module; it does not change optimization or dependency code. Both A/B builds must
use the same compiler flags and dependency lockfile.

## What the measurements mean

- Pipeline first/finish times measure delivery to the main-actor snapshot
  callback, not pixels or server generation time.
- Native first-text time additionally waits for text in the real UIKit view at
  a display-link callback. It is not a photon-level display measurement.
- Display-link gaps diagnose main-thread scheduling stalls. Simulator callbacks
  do not establish physical-device FPS or GPU frame drops. Idle callback pacing
  can also contribute gaps, especially in short fixtures.
- CPU is process user+system time during each sample. Preview loading and cold
  initialization should be measured separately from warmed comparisons.
- Renderer assertions compare the actual displayed Markdown nodes with a full
  parse, track view identity and height through completion, verify rendered math,
  and sample answer presence while a large final reasoning block is introduced.

Simulator validation does not replace final physical-device testing.
