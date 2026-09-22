# User bubble corners

The production `ChatMessageBubble` and its theme dependencies are compiled
directly into a small, offline test host. Only the message-role enum is stubbed;
no account, chat storage, or networking code is used.

Five rendering checks compare the actual bubble's alpha mask with its horizontal
and vertical reflections: short, multiline, very small, dark-mode, and
right-to-left layouts. Tiny antialiasing differences are allowed. The previous
18-point/4-point asymmetric shape fails these checks; the uniform rounded
rectangle passes. Two additional tests attach light/dark component screenshots
using freshly invented single-line, wrapped, and multiline messages.

## Run

Requires Xcode, XcodeGen, and an iOS simulator. No server is needed.

```sh
xcodegen generate --spec Tests/UserBubbleCorners/project.yml
xcodebuild -project Tests/UserBubbleCorners/BubbleTests.xcodeproj \
  -scheme BubbleTests \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/relay-bubble-tests \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/relay-bubble-results.xcresult test
```

## Before / after

The component screenshots below use the production bubble and theme on iOS 26.
The same seven tests also run on iOS 18. Before uses upstream revision
`a5c0cfa014c92b4875b7ccb2a64562205b258eb8` (v5.7.1).

| Appearance | Before | After |
| --- | --- | --- |
| Light | [Before](Screenshots/before-light.png) | [After](Screenshots/after-light.png) |
| Dark | [Before](Screenshots/before-dark.png) | [After](Screenshots/after-dark.png) |
