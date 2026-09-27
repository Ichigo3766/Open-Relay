# Dictation recovery regression tests

An isolated iOS test app compiles the production dictation service, recovery store,
and recording overlay. Networking and local ASR are mocked. Its only recording is
a freshly generated five-minute, mono AAC sine wave; microphone access is trapped.
No accounts, real conversations, credentials, or provider connections are used.

Requires Xcode, XcodeGen, Python 3, and FFmpeg:

```sh
cd Tests/DictationRecovery
python3 prepare.py
xcodegen generate
xcodebuild -project RecoveryQA.xcodeproj -scheme RecoveryQA \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -parallel-testing-enabled NO test
```

To demonstrate the original audio-loss bug on the baseline:

```sh
python3 prepare.py --baseline b38bfe91ab0d584c7ab22ac119adadae1af3dbf5
xcodegen generate
xcodebuild -project RecoveryQA.xcodeproj -scheme RecoveryQA \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -only-testing:RecoveryTests test
```

The baseline test intentionally fails because the failed upload deletes the audio.
Run `python3 prepare.py` again to restore the current implementation.

Tests cover repeated retries with identical five-minute audio, empty results, local
fallback, export without consumption, discard, overlapping attempts, cancellation,
late responses, durable draft receipts, relaunch, chat/account isolation, new-chat
promotion, and protection against overwriting unresolved recordings. UI tests
exercise the actual overlay, native menu and share UI, retry, relaunch, and Dynamic
Type. They also assert that every menu item stays above the recovery bar in light,
dark, and accessibility-size layouts. Attachments contain only the invented
workshop draft and synthetic audio.

These tests do not benchmark real transcription providers or claim direct Voice
Memos import. Save to Files is offered through the system share UI. A completed
recording is durable; playable recovery from a force-quit during active capture is
not guaranteed because the audio container may not have been finalized.
