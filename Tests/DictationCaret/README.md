# Dictation insertion visibility

## Reproduction and cause

The composer replaces its editor with the dictation overlay while recording or
transcribing. When a long transcript arrives, UIKit places the selection at the
end, but the recreated editor can still display the beginning of the draft.
The text is not truncated; its ending and insertion point are offscreen.

Reveal the existing selection once after layout following a programmatic text
change. Doing it immediately in `updateUIView` is too early: SwiftUI has not yet
assigned the editor its final width. No delayed dispatch, forced keyboard focus,
or unconditional selection/scroll changes are needed.

## Focused regression tests

The harness uses the production editor and composer layout. Only unrelated
attachment services are stubbed. Tests cover short and long transcripts,
appending after a Unicode draft, multiple widths, an already-mounted editor,
multiline text ending in a newline, normal typing in the middle, unchanged-draft
selection/scroll preservation, and the empty placeholder.

Requirements: Xcode, XcodeGen, Python 3, and an existing iOS simulator. Place
scratch/build output and the simulator on the designated development volume.
From the repository root:

```sh
export CARET_QA=/path/to/external/scratch
export CARET_DEVICE=your-simulator-uuid
python3 Tests/DictationCaret/prepare.py "$CARET_QA/Focused"
xcodegen generate --spec "$CARET_QA/Focused/project.yml" --project "$CARET_QA/Focused"
xcodebuild -project "$CARET_QA/Focused/DictationCaretQA.xcodeproj" \
  -scheme DictationCaretQA \
  -destination "platform=iOS Simulator,id=$CARET_DEVICE" \
  -derivedDataPath "$CARET_QA/Build" -parallel-testing-enabled NO \
  -resultBundlePath "$CARET_QA/fixed.xcresult" test
```

To reproduce without the fix, stage with `prepare.py --baseline f5b8ce8` into a
separate scratch directory and run the same tests. The caret visibility
assertions fail; the selection itself is already at the end.

## Full-app fixture and recordings

`fixture.py` is a loopback-only mock server. It returns freshly invented text
for an upload of generated silence. It never contacts a transcription provider.
`Seed.swift` uses the real recovery store to stage a completed recording under a
fixed synthetic conversation/account. The UI test retries it through the real
dictation completion path, then captures the inserted transcript and continued
typing. The same completion path is used after a first successful attempt.

Use only a disposable, synthetic-only app installation:

1. Install a baseline or fixed Open Relay build on the simulator.
2. In a separate virtual environment, install `aiohttp` and `python-socketio`;
   run `python3 Tests/DictationCaret/fixture.py`.
3. Connect the app to `http://127.0.0.1:18191`. Sign in with the fixture identity
   `demo@example.test` and any invented password. The fixture uses only the
   literal token `synthetic-token`. Select **Demo Model**.
4. Generate audio with FFmpeg and compile the seed helper:

   ```sh
   ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -b:a 32k \
     -map_metadata -1 "$CARET_QA/synthetic-silence.m4a"
   swiftc 'Open UI/Core/Services/DictationRecoveryStore.swift' \
     Tests/DictationCaret/Seed.swift -o "$CARET_QA/Seed"
   ```

5. Stop the app. Obtain its **synthetic-only** data container using
   `xcrun simctl get_app_container "$CARET_DEVICE" com.openui.openui data`.
   Run the seed helper with that container's
   `Library/Application Support/DictationRecovery` directory and the generated
   audio path. The helper replaces only the fixed fixture context.
6. Copy `full-app.yml` and `FullAppUITests.swift` into an external test directory,
   then generate the project with XcodeGen (`--spec full-app.yml`). Run its
   `DictationCaretFullApp` scheme against the same simulator, with external
   DerivedData and an `.xcresult` bundle.
7. Export test attachments with `xcrun xcresulttool export attachments`.

The UI test checks transcript delivery and continued typing; screenshots/video
show the viewport before tapping. The focused UIKit tests above assert the
actual caret geometry. This tests client insertion, not speech-recognition
accuracy or provider reliability.

## Verified results

Tested from `f5b8ce8` (5.9), using Xcode 27.0 and an iPhone 16 Pro simulator
running iOS 27.0:

- Baseline: five of nine focused tests fail (eight visibility assertions).
- Fixed: all nine focused tests pass; Release app build passes.
- Full-app transcript delivery and continued typing pass on both builds. The
  recorded difference is the viewport immediately after insertion, before a tap.
- For the 2,119-UTF-16-unit fixture at 328-point editor width, the baseline
  viewport starts at 0 while the caret starts around 916 points down. The fixed
  viewport starts at 783 points, making the ending visible without interaction.

The before/after clips are direct XCUITest screen recordings, trimmed to the
same interaction and encoded at 30 fps without changing playback speed.

## Privacy

All fixture text, accounts, and audio are freshly synthetic. No personal chats,
recordings, instance settings, credentials, or raw device logs are included.
Public evidence consists only of reviewed simulator captures with metadata and
audio removed. No messages are sent to a real model.
