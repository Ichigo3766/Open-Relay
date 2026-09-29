# Dictation Live Activity checks

Baseline: Open Relay 6.2, `84ea58b4e05b967fde923ac09206f17668777450`.

The feature adds a native recording indicator and elapsed timer to the Lock Screen
and Dynamic Island for composer dictation, independently of voice calls. Activity
data contains only timestamps, never chat, account, model, transcript, or audio data.

Recording starts before the activity is requested. Stop, discard, navigation,
audio interruptions, media-service resets, and recorder failures end the activity.
Interrupted audio stays in the existing recovery store; it is not auto-submitted.
The app's background read-aloud cleanup now leaves an active microphone's session
alone. Completed recording files use the same after-first-unlock protection as
their recovery metadata.

The system draws the elapsed timer. The app confirms capture at most once every
30 seconds, with a 90-second freshness window. The timer's upper bound prevents
indefinite counting if the process disappears. iOS controls stale-state redraws:
the simulator delayed `isStale` even after the deadline, so **immediate changes to
the status label after process death are not guaranteed**. Ordinary stop and
interruption paths explicitly end the activity; relaunch removes old activities.

## Automated checks

From this directory, with XcodeGen installed, choose an existing simulator and
external build/output directories, then run:

```sh
xcodegen generate
xcodebuild -project DictationActivityQA.xcodeproj -scheme DictationActivityQA \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$QA_BUILD" -resultBundlePath "$QA_RESULTS" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
python3 background_audio.py --output "$BACKGROUND_CHECKS"
```

`RecordingTests.swift` compiles the actual production service and controller with
deterministic platform doubles. It never opens a microphone or contacts a server.
It covers both engines, permissions/start failures, disabled/unavailable activity
support, interruptions, audio-service reset, encoder failure, navigation/discard,
stale callbacks, silent recorder termination, throttled updates, cleanup races,
and the privacy boundary of the activity payload.

The stopped-recorder regression also verifies that an invalid/reset `currentTime`
cannot replace the last observed duration with zero. It fails without the guard
in `finishRecording()` and passes with it.

`background_audio.py` executes the exact app background-cleanup block against a
24-case matrix of dictation states, voice-call ownership, and read-aloud engines.
The baseline fails three active-dictation cases; the fix passes all 24. Use
`--revision 84ea58b` to reproduce the baseline failures.

The lifecycle suite also runs on macOS without a simulator:

```sh
python3 portable_tests.py --output "$QA_BUILD/lifecycle"
python3 portable_tests.py --without-duration-guard --output "$QA_BUILD/duration-before"
```

The portable runner stages the production sources and removes unavailable iOS
framework imports and file-protection operations. It uses the same platform
doubles and XCTest cases; it does not test actual audio capture, native ActivityKit
presentation, or iOS Data Protection. The second command deliberately removes
the stopped-recorder duration guard and must fail its regression test.

The native UI harness compiles the production widget and controller into an
isolated app. It uses a synthetic five-minute start timestamp, not recorded audio.
The UI test checks timer advancement without app updates, opening the app by
tapping the activity, bounded expiry, and removal after Stop. Screenshot attachments
come from the actual system-rendered widget, not a recreation.

## Device verification still required

On the v6.2 base, 13 portable lifecycle tests passed, one device-only test was
skipped, all 24 background-audio cases passed, and the native presentation harness
compiled in Release for iOS. The v6.2 background regression failed before the
fix; removing the duration guard also fails its focused regression test.

Earlier native validation of the same production controller, attributes, and
widget on the v6.0 base used iOS 26.5: 13 lifecycle tests passed, one device-only
test was skipped, and the native UI scenario passed in light and dark appearance.
That scenario verifies bounded expiry, not the timing of iOS's stale-label redraw.
See [visual evidence and its provenance](Evidence/README.md). These captures
are historical native-harness evidence, not a new v6.2 device test.

Simulator checks cannot establish real microphone capture while physically locked,
Data Protection enforcement, phone-call/Bluetooth interruptions, or device-specific
power-management behavior. The file-protection assertion explicitly skips on the
simulator. On a device, verify a long recording with a locked screen, unlock and
check the saved duration/audio, then repeat with an interruption and with Live
Activities disabled. Also check the native stale-status timing after force-quit;
this is not an instantaneous microphone-status guarantee.
