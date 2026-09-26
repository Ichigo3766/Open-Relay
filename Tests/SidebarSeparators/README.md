# Sidebar separator regression

The production sidebar previously rendered two adjacent separators when folders
were present and Channels was hidden. Separators should follow visible sections,
including empty-but-visible headers, rather than the number of folder/channel rows.

## Reproduction and UI tests

Only invented in-memory fixture data is used. Use a disposable simulator with no
real accounts; the QA root rejects non-loopback server configurations. Nothing in
this directory is included in the shipping app.

1. Start `python3 Tests/SidebarSeparators/fixture.py` (loopback port 18195).
2. Run `python3 Tests/SidebarSeparators/prepare_qa.py /path/to/new/qa/app
   --baseline b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`.
3. Build the copied `Open UI.xcodeproj` and install it in the disposable simulator.
4. In this directory, run `xcodegen generate`, then build/test the generated
   `SidebarSeparators` scheme against that simulator. `testBeforeLight` and
   `testBeforeDark` capture the original two-separator layout. The actual
   regression test, `testChannelsDisabledLight`, must fail on the baseline
   (two separators instead of one).
5. Refresh the same QA copy with `prepare_qa.py /path/to/qa/app --refresh`, rebuild,
   and reinstall. Run the suite excluding `testBeforeLight` and `testBeforeDark`.

The QA script adds an accessibility identifier to the real separator view and
uses the production `MainChatView`, not a recreation. The same instrumentation
and type-checker-only expression split are applied to both versions.

Coverage: channels disabled by configuration or permissions; channels enabled;
empty folder/channel lists; folders denied by permissions or unavailable (403);
shared-only folders; Channels alone; no Chats section; light and dark screenshots.

Inspect exported screenshot attachments before publication. Do not publish raw
build logs or result bundles.

## Verified results

On an iPhone 16 Pro simulator (iOS 27, Xcode 27), both app versions built
successfully. The baseline reproduced two separators in both themes and failed
the one-separator regression. All 11 post-fix UI checks passed, including that
same regression.
