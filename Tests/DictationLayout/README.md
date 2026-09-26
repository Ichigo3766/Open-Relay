# Long dictation scrolling regression

The unchanged composer at `b38bfe9` can display only the first part of a long
dictation after replacing the recording overlay with a new text view. The full
transcript remains in `UITextView.text`, but placeholder constraints against the
scroll view's content edges overwrite its `contentSize`. Scrolling cannot reach
the remaining text. Pinning the placeholder to `frameLayoutGuide` keeps it out
of the content-size calculation.

## Focused reproduction

From this directory, run:

```sh
python3 prepare.py --baseline b38bfe9
xcodegen generate
xcodebuild -project DictationLayoutQA.xcodeproj -scheme DictationLayoutQA \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

`prepare.py` copies the production text view and extracts the production layout
without changing either implementation. Only unrelated attachment dependencies
are stubbed. Tests use an actual UIKit text view hosted by SwiftUI in a window.

The recreated-composer test fails before the fix: 2,825 characters are present,
but the scrollable content height is zero. Run `python3 prepare.py` without a
baseline and repeat the test command to verify the working tree instead.
The same fixture then has a 1,242-point content height at a 328-point text width.

Tests cover recreation after processing, updating an existing composer, appending
to a draft, deletion, clearing to the placeholder, and longer transcripts at
several widths. They verify the complete text, scrollable content size, and
that the last character is reachable without an edit to repair layout.

## Full-app visual reproduction

Use a disposable simulator with no real accounts. Start `python3 fixture.py`
(loopback port 18201), then run `python3 full_app.py /path/to/new/qa-copy`.
Build and install that copied app, and run the `DictationFullApp` UI-test scheme
against the same simulator. The QA root refuses non-loopback server configs.

The copy keeps the real microphone button, processing overlay, transcript
callback, and composer. Only recording/transcription is replaced with a fixed,
invented transcript, so no microphone audio, real server, or real chats are used.
The full-app tests exercise light/dark mode and an initially visible keyboard,
swipe through the transcript, and capture screenshots for visual inspection.
The QA-only expression split in `full_app.py` avoids a large Swift type-checking
expression; it does not ship in the app.

Never publish raw result bundles or logs. Review exported synthetic captures
before attaching them to a report.

## Validation

- Six focused tests pass on iOS 26.5 and iOS 27, including 11,300-character
  transcripts at multiple widths, appending, deleting, and clearing.
- The full-app simulator build succeeds. Three UI tests pass on iOS 27
  (light mode, dark mode, and dictation started with the keyboard visible).
- Captures after six upward swipes show paragraphs 1–5 before the fix and
  paragraphs 29–32 plus `END OF TRANSCRIPT` afterward. The focused tests also
  assert that the final character is reachable without first editing the text.

This verifies transcript insertion and scrolling, not speech recognition
accuracy; the transcript is supplied at the transcription-completion boundary.
