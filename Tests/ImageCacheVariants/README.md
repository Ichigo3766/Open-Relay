# Image-cache variant checks

Add `ImageCacheVariantTests.swift` and the production
`Open UI/Core/Services/ImageCacheService.swift` to an isolated iOS XCTest target.
Run on an iOS simulator with Swift 5 language mode, matching the app target.
The eight tests generate fresh pixels and intercept only `image-fixture.invalid`;
they never access a real server, account, or recording.

Coverage: memory/disk resolution identity, mixed-size concurrent download
deduplication, same-size decoded identity, eviction, replacement, invalid-data
retry, truncated PNG/ETag recovery, and nonpositive size normalization. A request
test checks synthetic authorization/custom headers and retries after a 401
response. A
recognized but incomplete PNG must not save a validator: otherwise the retry
receives a 304 and repeatedly reuses the undecodable bytes. This regression
fails without clearing failed decodes and their validators and passes with it.
The full app still needs integration
checks for inline display/export and existing authentication/invalidation paths.
