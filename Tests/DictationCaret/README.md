# Dictation composer sizing

A programmatic insertion is measured before SwiftUI assigns the editor its final
width. The previous height can survive that layout pass: a wider editor leaves
blank rows below the text, and a narrower editor can clip its ending. Recalculate
height at the actual width before the existing one-shot selection reveal.

This does not insert, delete, or normalize characters. The server transcription
path already trims trailing whitespace. Keep normal typing, selection, manual
scrolling, and the eight-line height limit unchanged.

## Focused regression tests

The host uses the production editor and composer layout; only unrelated attachment
services are stubbed. Xcode, XcodeGen, Python 3, and an installed simulator are
required. Keep build output and simulator storage on the designated development
volume. From the repository root:

```sh
export CARET_QA=/path/to/external/scratch
export CARET_DEVICE=your-simulator-uuid
python3 Tests/DictationCaret/prepare.py "$CARET_QA/Focused"
xcodegen generate --spec "$CARET_QA/Focused/project.yml" --project "$CARET_QA/Focused"
xcodebuild -project "$CARET_QA/Focused/DictationCaretQA.xcodeproj" \
  -scheme DictationCaretQA -destination "platform=iOS Simulator,id=$CARET_DEVICE" \
  -derivedDataPath "$CARET_QA/Build" -parallel-testing-enabled NO \
  -collect-test-diagnostics never -resultBundlePath "$CARET_QA/fixed.xcresult" test
```

For the baseline, stage another host using `prepare.py --baseline 4b54725`.
`testMediumDictationNaturalHeight` reproduces the extra row at phone width;
`testTranscriptLengthSweep` also covers narrow and wide layouts.

Tests cover exact text/UTF-16 selection, short and long transcripts, appended
dictation, multiline content, four widths, keyboard focus, continued typing,
empty drafts, and unchanged-draft selection/scroll preservation.

## Full-app synthetic reproduction

`fixture.py` is a loopback-only server. It returns invented text for generated
silent audio, including trailing whitespace to exercise existing trimming. It
does not call an ASR provider or retain uploaded audio. `Seed.swift` stages a
completed recording using the production recovery store. Retrying it exercises
the same transcription completion path as stopping a recording.

Use only a synthetic-only simulator installation:

1. Install the baseline or fixed app. In a separate Python environment with
   `aiohttp` and `python-socketio`, run:
   `DICTATION_CASE=medium python3 Tests/DictationCaret/fixture.py`.
2. Connect the app to `http://127.0.0.1:18191`. Sign in with `demo@example.test`
   and any invented password. The fixture identity is `demo-user`, with the
   literal token `synthetic-token`. Select **Demo Model**.
3. Generate silence and build the seeder:

   ```sh
   ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -b:a 32k \
     -map_metadata -1 "$CARET_QA/synthetic-silence.m4a"
   swiftc 'Open UI/Core/Services/DictationRecoveryStore.swift' \
     Tests/DictationCaret/Seed.swift -o "$CARET_QA/Seed"
   ```

4. Stop the app. Resolve its data container with
   `xcrun simctl get_app_container "$CARET_DEVICE" com.openui.openui data`
   **after each installation**, as it may change. Run `Seed` with that container's
   `Library/Application Support/DictationRecovery` path and the synthetic audio
   path. It replaces only the fixed fixture context.
5. Copy `FullAppUITests.swift` and `full-app.yml` to an external test directory,
   generate the project using XcodeGen, and run the `DictationCaretFullApp` scheme
   with `-only-testing:DictationCaretFullAppTests/FullAppUITests/testMediumDictation`.
   Use external DerivedData/result paths and disable parallel testing.
6. Export screenshots and native screen recordings with
   `xcrun xcresulttool export attachments`. Review individual assets before sharing;
   never publish raw test results, device logs, or UI hierarchy dumps.

For the long-transcript check, restart the fixture without `DICTATION_CASE`, seed
again, and run only `testCompletedDictation`. Both full-app cases assert that the
first Backspace deletes the last punctuation immediately and typing appends at
that position, with no intervening padding. They do not send a chat message.

## Validation

Baseline: Open Relay 6.1 (`4b54725`), built with Xcode 27.0.

- Phone-width regression: baseline editor height 133.67 pt versus 114.67 pt
  required by the text. The fixed version passes the same assertion.
- Full app, iOS 26.5: identical 244-character transcript, editor height reduced
  from 100.33 pt to 83.67 pt, removing one empty row. Before/after screenshots and
  screen recordings use the same fixture. Exact-text and Backspace checks pass.
- All 14 focused tests pass on iOS 26.5. Full-app medium and long completion,
  first-Backspace, and continued-typing checks pass on the fixed Release build.
- Baseline and fixed Release builds pass. Focused tests validate text and layout
  independently of transcription quality.

All fixture content, accounts, and audio are synthetic. No private chats,
recordings, server configuration, credentials, or user logs are used. This tests
client insertion/layout, not provider recognition accuracy or a physical phone.
