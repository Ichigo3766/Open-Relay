import Foundation
import UIKit
import os.log

/// Thread-safe in-process store for base64 image data URIs extracted from message content.
///
/// ## Why this exists
/// When image-generation tools return results, the full base64 payload is embedded directly in
/// the assistant message's `content` field as markdown image syntax:
///
///     ![Image](data:image/png;base64,<500 KB of base64 characters>)
///
/// Loading that message string into SwiftUI causes multiple freezes on the main thread:
///
/// - `URL(string: dataURI)` validates the full 500 KB string
/// - `NSRegularExpression` in `findMarkdownImages` scans the full 500 KB string
/// - The `SegmentCache` does a byte-for-byte equality check against the 500 KB string
/// - Multiple visible messages × 500 KB = several seconds of main-thread work
///
/// ## How it solves the problem
/// At JSON-parse time (always off the main thread inside `loadConversation()`) each base64 data
/// URI is extracted from the content string and stored here under a short UUID token. The message
/// content is rewritten to use the compact placeholder `imgcache://TOKEN` instead. From that
/// point on, the content string is tiny and all expensive operations are O(1).
///
/// `MarkdownInlineImageView` detects the `imgcache://` scheme and resolves the token back to the
/// original data URI for background decoding — exactly the same `Task.detached` path that was
/// already in place for `data:` URIs.
///
/// ## Thread safety
/// All reads and writes are serialised through a single `NSLock`. Registration happens exactly
/// once per message load; reads happen on arbitrary threads (SwiftUI body, Task.detached).
/// The store is never cleared during the app session — entries are lightweight (just a string
/// alias; the heavy UIImage decode lives in `MarkdownInlineImageView.base64ImageCache`).
nonisolated final class InlineImageStore: @unchecked Sendable {
    static let shared = InlineImageStore()
    private init() {}

    private let lock = NSLock()
    private var store: [String: String] = [:] // token → data URI string

    // MARK: - Public API

    /// Registers a full `data:image/…;base64,…` URI and returns a compact token URL string
    /// (`imgcache://TOKEN`) that can be embedded in markdown content without performance cost.
    ///
    /// If the exact same data URI was previously registered the existing token is reused, so
    /// re-loading the same conversation doesn't accumulate duplicate entries.
    func register(dataURI: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        // Compare complete content so equal-length images with shared headers stay distinct.
        let dedupKey = dataURI
        if let existing = dedupIndex[dedupKey] {
            return "imgcache://\(existing)"
        }

        let token = UUID().uuidString
        store[token] = dataURI
        dedupIndex[dedupKey] = token
        return "imgcache://\(token)"
    }

    /// Looks up the original `data:image/…;base64,…` string for a token URL.
    /// Returns `nil` if the token is unknown (should never happen in normal use).
    func resolve(token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[token]
    }

    /// Resolves a full `imgcache://TOKEN` URL string to the stored data URI.
    func resolve(urlString: String) -> String? {
        guard urlString.hasPrefix("imgcache://") else { return nil }
        let token = String(urlString.dropFirst("imgcache://".count))
        return resolve(token: token)
    }

    // MARK: - Internals

    /// Reverse map: dedup-key → token, so identical images share one store entry.
    private var dedupIndex: [String: String] = [:]
}

// MARK: - Content extraction helpers

extension InlineImageStore {

    /// Scans `content` for inline markdown images whose URL is a `data:image/` data URI.
    /// Replaces each with a compact `imgcache://TOKEN` placeholder and returns the new string.
    ///
    /// Fast path: if the content doesn't contain `](data:image/` nothing is done (O(1) check).
    ///
    /// This is designed to be called from a background thread at JSON-parse time so the
    /// replacement happens before SwiftUI ever sees the content string.
    nonisolated static func extractAndReplace(content: String) -> String {
        // Fast exit — most messages don't contain image gen results.
        guard content.contains("](data:image/") else { return content }

        var result = content
        // Walk through all occurrences. We use a simple character-scan rather than regex so
        // the loop itself runs in O(N) on the already-small non-image portions.
        var searchRange = result.startIndex..<result.endIndex

        while true {
            // Find the markdown image open bracket sequence
            guard let imgStart = result.range(of: "![", range: searchRange) else { break }
            // Find the closing bracket + opening paren sequence from imgStart
            guard let parenOpen = result.range(of: "](", range: imgStart.upperBound..<result.endIndex) else { break }
            // Check the URL that follows opens with data:image/
            let afterParenOpen = parenOpen.upperBound
            guard result[afterParenOpen...].hasPrefix("data:image/") else {
                // Not a data URI — skip past the bracket and continue
                searchRange = imgStart.upperBound..<result.endIndex
                continue
            }
            // Find the closing paren — walk forward character by character
            guard let parenClose = result.range(of: ")", range: afterParenOpen..<result.endIndex) else {
                // Incomplete URI (shouldn't happen in stored messages) — stop.
                break
            }

            // Extract the full data URI
            let dataURI = String(result[afterParenOpen..<parenClose.lowerBound])

            // Only process genuine base64 image data URIs
            guard dataURI.hasPrefix("data:image/"), dataURI.contains(";base64,") else {
                searchRange = parenClose.upperBound..<result.endIndex
                continue
            }

            // Register in store and get compact token URL
            let tokenURL = InlineImageStore.shared.register(dataURI: dataURI)

            // Extract alt text
            let altText = String(result[imgStart.upperBound..<parenOpen.lowerBound])

            // Build replacement — same markdown image syntax but with the tiny token URL
            let replacement = "![\(altText)](\(tokenURL))"

            // Replace the entire ![alt](data:...) span
            let fullRange = imgStart.lowerBound..<parenClose.upperBound
            result.replaceSubrange(fullRange, with: replacement)

            // Advance search past the replacement (which is much shorter than what we replaced)
            let newSearchStart = result.index(imgStart.lowerBound, offsetBy: replacement.count, limitedBy: result.endIndex) ?? result.endIndex
            searchRange = newSearchStart..<result.endIndex
        }

        return result
    }
}
