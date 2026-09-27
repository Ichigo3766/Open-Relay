# Completed-message bottom spacing

The last conversation turn reserved at least one viewport even after streaming
finished whenever the full chat overflowed. The content-height test measured the
already-padded content, so the empty space could keep itself active. Finished
turns now use their natural height; streaming still reserves writing space.

## Focused regression

```sh
python3 -m unittest discover -s Tests/ChatBottomGap -p 'test_*.py' -v
```

This executes the actual minimum-height closure extracted from `ChatDetailView`.
It covers completed history, an already-padded measurement, a short chat, active
streaming, an older pagination window, and a keyboard-reduced viewport. The
completed-history, padded-measurement, and keyboard cases fail on upstream
`b38bfe91ab0d584c7ab22ac119adadae1af3dbf5` (5.8).

## Full-app UI regression

Install the app build under test on a disposable iOS simulator. Do not use a
simulator connected to a personal account. The fixture binds only to loopback,
contains freshly invented craft chats, and rejects generation/configuration
writes. It does not contact or import Open WebUI.

```sh
python3 Tests/ChatBottomGap/mock_server.py
xcodegen generate --spec Tests/ChatBottomGap/project.yml
xcodebuild -project Tests/ChatBottomGap/SpacingTests.xcodeproj \
  -scheme SpacingTests \
  -destination 'platform=iOS Simulator,id=SYNTHETIC_SIMULATOR_UUID' \
  -derivedDataPath /tmp/relay-spacing-build \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/relay-spacing-results.xcresult test
```

The tests sign in to `http://127.0.0.1:18089` using only fixture credentials,
measure the last action row against the composer, and attach light/dark
screenshots. Coverage includes a completed reply in a longer chat, a long reply,
returning from older messages, switching conversations, keyboard dismissal, and
a short conversation that fits the screen. Screenshots must only come from this
fixture, never from a real conversation.

The comparison was run on an iPhone simulator with Xcode 27 / iOS 27. Full-app
builds required the compiler-only view-expression splits from #272 in a separate
QA checkout; those unrelated splits are not included in this change. The before
app retained upstream's last-turn sizing logic unchanged.

Results: all five UI tests pass after the fix. Both light/dark baseline tests
fail on the same assertion: 222.7 pt between the final action and composer,
versus 29.7 pt afterward. All six focused sizing checks pass afterward; three
fail on the baseline policy.
