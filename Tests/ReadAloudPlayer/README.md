# Read-aloud player validation

The harness compiles the production splitting, preprocessing, and playback files directly into a small iOS app. Unit tests use valid synthetic PCM audio through the real AVQueuePlayer. UI tests drive the separately installed Open Relay app against a loopback Open WebUI-shaped server; every account, message, and audio recording is invented.

Requires Xcode, an iOS 18.1+ simulator, Python 3, and XcodeGen. Run from the repository root, using a disposable simulator and an output directory outside the checkout:

```sh
xcodegen generate --spec Tests/ReadAloudPlayer/project.yml
python3 Tests/ReadAloudPlayer/mock_server.py /tmp/relay-player-audio
```

Keep the fixture running in a separate terminal. Build the normal `Open UI` scheme for the simulator and install its app with `xcrun simctl install`. Then run:

```sh
xcodebuild -project Tests/ReadAloudPlayer/ReadAloudTests.xcodeproj \
  -scheme ReadAloudTests -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/relay-player-tests -resultBundlePath /tmp/relay-player-results.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The UI suite signs in to `http://127.0.0.1:18081` with a synthetic account. Use a fresh simulator; never run it against an existing account. Screenshots are retained in the result bundle. Fixture requests can be inspected with `GET /fixture`; fixture-only `POST /fixture` resets observations and sets simulated server defaults, delay, or failures.

Native tests cover server inheritance and all chunk modes, playback/completion, buffering underruns, pause during generation, speed and Now Playing metadata, cross-chunk seeking, seeking beyond available audio, replay without synthesis, failed generation and corrupt audio retry, replacement/cancellation, temporary file cleanup, interruptions, and route changes. UI tests cover settings, actual speech API payloads, player controls, background playback, selection-based restart, errors, Admin Audio updates, and non-admin playback with the admin endpoint returning HTTP 403.

The player is for server-backed message read-aloud. It refreshes `/api/config`, calls the existing authenticated `/api/v1/audio/speech` API, caches each returned audio file for the session, and uses AVQueuePlayer for playback. Local and Apple speech engines retain their existing behavior; live voice calls retain incremental synthesis. Starting a voice call closes read-aloud.

Tap the elapsed time to open selectable playback text. Duration and scrubbing appear in this sheet after generation finishes; skipping forward is limited to available audio. “Play from here” starts new synthesis from selected text. Exact word highlighting is deliberately absent because the speech endpoint supplies audio without word timestamps. Provider limits still apply to Whole Message; failures are retryable and the user can select smaller chunks.

Simulator tests exercise native playback and the API contract, not a real provider’s quality or physical-device Bluetooth/lock-screen behavior. Native Now Playing commands are registered for device testing.

## Validation performed

Based on Open Relay v5.7 (`c15e37f`), built with Xcode 26.5. The 15 native tests pass on iOS 18.4 (iPhone 16) and iOS 26.5 (iPhone 17 Pro), including natural playback across chunk boundaries. All five app UI scenarios pass on iOS 26.5. Playback controls, background audio, scrubbing, and selection-based restart also pass on iOS 18.4 in dark mode; screenshots were inspected on both versions. The existing message-action preference checks pass (16/16); the existing local voice/reasoning regression probe passes (48/48).
