# New-chat suggestion visibility

`Settings → Chat Behavior → New Chats → Show New Chat Suggestions` controls
the welcome-screen prompt cards only. It defaults to on and persists on this
device. Model-specific and server-default prompts share the same visibility
guard; the greeting, composer, and follow-up suggestions are unchanged.

## Server compatibility

Open WebUI v0.11.4 and current upstream render these prompts without a per-user
hide preference ([Suggestions.svelte](https://github.com/open-webui/open-webui/blob/v0.11.4/src/lib/components/chat/Suggestions.svelte)).
Its `insertSuggestionPrompt` preference changes what happens when a prompt is
tapped; it does not hide the cards. This toggle is explicitly local rather than
inventing an unsupported server preference or clearing shared prompt definitions.

## Source regression

```sh
python3 Tests/NewChatSuggestions/audit.py
```

Three new guards fail on baseline `b38bfe9`; the independent follow-up guard
passes on both versions.

## Synthetic UI reproduction

Use a disposable simulator containing only loopback fixture servers. The QA
entry point rejects saved non-loopback servers. No real server, account, model
request, or chat is used. The fixture never reads a database.

```sh
python3 Tests/NewChatSuggestions/fixture.py
# In another terminal, choose a new external directory:
python3 Tests/NewChatSuggestions/prepare_qa.py /tmp/suggestions-qa --baseline b38bfe9
```

Build/install this copy using the normal iOS simulator scheme. The copy replaces
only the app entry point with synthetic setup, and makes an identical test-only
chat-expression split in both versions for Xcode's type checker. Neither change
ships. After baseline screenshots, run the script with `--refresh` instead of
`--baseline` to build the updated version incrementally.

```sh
xcrun simctl privacy SIMULATOR_ID revoke photos-add com.openui.openui
cd Tests/NewChatSuggestions
xcodegen generate
xcodebuild -project NewChatSuggestionsTests.xcodeproj -scheme NewChatSuggestions \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:NewChatSuggestionsUITests/NewChatSuggestionsUITests/testAfterLight \
  -only-testing:NewChatSuggestionsUITests/NewChatSuggestionsUITests/testAfterDark \
  -only-testing:NewChatSuggestionsUITests/NewChatSuggestionsUITests/testNoServerSuggestions \
  -only-testing:NewChatSuggestionsUITests/NewChatSuggestionsUITests/testHiddenOnFirstRender test
```

For baseline captures run `testBeforeLight` and `testBeforeDark` instead. The UI
tests cover default-on, immediate hide/re-enable, persistence across relaunch,
another new chat, model/admin prompt sources, and an empty server prompt list.
The fixture counts server writes to catch accidental settings changes or chats.

Publish only reviewed screenshot attachments, never raw logs or result bundles.
All example prompts and identities are freshly invented.

## Verified results

On an iPhone 16 Pro simulator running iOS 27, baseline `b38bfe9` and updated
QA app builds pass. Both baseline capture tests and all four updated UI tests
pass. Four source checks pass; the three new checks fail on the baseline.
The light/dark hide/re-enable flows record zero server writes, including after
relaunching and opening another new chat.
