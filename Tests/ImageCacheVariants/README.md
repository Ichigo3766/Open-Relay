# Image-cache variant checks

Add `ImageCacheVariantTests.swift` and the production
`Open UI/Core/Services/ImageCacheService.swift` to an isolated iOS XCTest target.
Run on an iOS simulator with Swift 5 language mode, matching the app target.
The nine tests generate fresh pixels and intercept only `image-fixture.invalid`;
they never access a real server, account, or recording.

Coverage: memory/disk resolution identity, mixed-size concurrent download
deduplication, same-size decoded identity, eviction, replacement, invalid-data
retry, truncated PNG/ETag recovery, and nonpositive size normalization. A request
test checks synthetic authorization/custom headers and retries after a 401
response. Avatar prefetch stays at 256 pixels, can immediately fill smaller
display sizes, and never satisfies an original-size request with a thumbnail.
A recognized but incomplete PNG must not save a validator: otherwise the retry
receives a 304 and repeatedly reuses the undecodable bytes. This regression
fails without clearing failed decodes and their validators and passes with it.

A Release iOS 27 full-app check scrolled through eight synthetic inline images,
switched to another chat, and reopened the images (40 gestures total). Request
counts were 16 initially / 24 cumulative on the baseline and 8 / 8 with this
change. Native tests establish original-resolution reuse and request headers;
the scrolling check alone does not establish export behavior.
