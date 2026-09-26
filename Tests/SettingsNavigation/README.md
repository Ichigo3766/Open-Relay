# Settings navigation regression

The two preference pickers must use the existing Settings navigation stack,
like Appearance and Accessibility. Back discards an unsaved model choice;
the accessible Save checkmark persists it. A downward sheet gesture dismisses
Settings, not a second picker sheet.

## Source checks

```sh
python3 Tests/SettingsNavigation/audit.py
```

The same checks fail on the baseline: nested sheets/stacks, text Cancel controls,
tinted selection backgrounds, and prefix-based language selection.

## Synthetic UI checks

Use a disposable simulator with **only loopback fixture servers**. No actual
server, database, account, or chat is needed. The test-only app entry point rejects
saved non-loopback servers and opens the real `SettingsView` in a sheet.

```sh
python3 Tests/SettingsNavigation/fixture.py
# In another terminal, use a new directory outside the checkout:
python3 Tests/SettingsNavigation/prepare_qa.py /tmp/settings-qa
```

Build/install the copied app with the normal simulator scheme. `--baseline b38bfe9`
prepares the tested baseline instead of working-tree changes.
The copy has a test-only Settings entry point and
an identical chat-expression split in both versions for Xcode's type checker.
Neither adjustment ships in the app.
After baseline captures, `--refresh` replaces that QA copy with the working-tree
version so the after build can reuse its compiled dependencies.

Before screenshots, deny the disposable app's optional first-launch Photos prompt:

```sh
xcrun simctl privacy SIMULATOR_ID revoke photos-add com.openui.openui
cd Tests/SettingsNavigation
xcodegen generate
xcodebuild -project SettingsNavigationTests.xcodeproj -scheme SettingsNavigation \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testAfterLight \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testAfterDark \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testModelSaveAndDiscard \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testLanguageSelectionAndCancel \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testLanguageApplyAndReset \
  -only-testing:SettingsNavigationUITests/SettingsNavigationUITests/testBackAndDismissGestures test
```

For baseline captures, run `testBeforeLight` and `testBeforeDark` only.
The UI tests cover model search, saving versus discarding, preservation of
unrelated server preferences, exact language selection (system, English,
English UK, Portuguese Brazil), cancelling/applying/resetting the language, and native
back/sheet gestures for both changed pages and the two reference pages.
Run `testDemo` with simulator video recording for the same navigation sequence
before and after. Recordings demonstrate real transitions, not animated mockups.

All screenshot attachments show freshly invented models and an empty library.
Only reviewed screenshots or simulator recordings should be published, never
raw logs or result bundles.

## Verified results

Against baseline `b38bfe9` on an iPhone 16 Pro simulator (iOS 27): both app builds
pass; all four source checks fail before and pass after. Both baseline capture
tests and all six after tests pass, including four native back/dismiss routes,
model save/discard and sibling-preference preservation, four language-selection
cases, restart-prompt cancellation, and language apply/reset across relaunches.
