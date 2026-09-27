# Image-cache variant checks

Add `ImageCacheVariantTests.swift` and the production
`Open UI/Core/Services/ImageCacheService.swift` to an isolated iOS XCTest target.
Run on an iOS simulator with Swift 5 language mode, matching the app target.
The six tests generate fresh pixels and intercept only `image-fixture.invalid`;
they never access a real server, account, or recording.

Coverage: memory/disk resolution identity, mixed-size concurrent download
deduplication, same-size decoded identity, eviction, replacement, invalid-data
retry, and nonpositive size normalization. The full app still needs integration
checks for inline display/export and existing authentication/invalidation paths.
