import SwiftUI
import ImageIO
import os.log

/// A thread-safe, memory-efficient image cache with automatic eviction.

actor ImageCacheService {

    /// Shared singleton instance.
    static let shared = ImageCacheService()

    // MARK: - Private Storage

    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.openui", category: "ImageCache")

    /// Maximum number of images to hold in memory.
    private let memoryCacheLimit = 200

    /// Maximum disk cache size in bytes (50 MB).
    private let diskCacheSizeLimit: Int = 50 * 1024 * 1024

    /// Active download tasks keyed by URL string to deduplicate requests.
    private var activeTasks: [String: Task<UIImage?, Never>] = [:]

    // MARK: - Global Concurrency Cap

    /// Number of network image downloads currently in flight.
    /// Capped at `maxConcurrentDownloads` to prevent server flooding during fast scroll.
    private var activeDownloadCount: Int = 0

    /// Maximum simultaneous image downloads. Keeps request volume manageable
    /// even when 300 model rows become visible almost simultaneously.
    private let maxConcurrentDownloads = 50

    /// Tasks waiting for a download slot, in FIFO order.
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Acquires a download slot. Suspends the caller if `maxConcurrentDownloads` are active.
    private func acquireDownloadSlot() async {
        if activeDownloadCount < maxConcurrentDownloads {
            activeDownloadCount += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingContinuations.append(continuation)
        }
        activeDownloadCount += 1
    }

    /// Releases a download slot and wakes the next pending caller, if any.
    private func releaseDownloadSlot() {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        if !pendingContinuations.isEmpty {
            let next = pendingContinuations.removeFirst()
            next.resume()
        }
    }

    // MARK: - Content Deduplication

    /// Maps SHA-256 of decoded pixel data → canonical UIImage.
    /// When 290 models all return the same favicon, only one UIImage is kept in memory.
    nonisolated(unsafe) private var imageDeduplicationMap: [Int: UIImage] = [:]

    /// Returns the canonical UIImage for a given image, deduplicating by pixel checksum.
    private func deduplicatedImage(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        // Use (width, height, dataProvider pointer) as a lightweight identity check.
        // The dataProvider address is stable for the same backing store.
        let identity = cgImage.width &* 397 &+ cgImage.height &* 31
            &+ (ObjectIdentifier(cgImage.dataProvider! as AnyObject).hashValue)
        if let existing = imageDeduplicationMap[identity] {
            return existing
        }
        imageDeduplicationMap[identity] = image
        return image
    }

    // MARK: - Cloudflare Support

    /// Custom headers (e.g. User-Agent) that must be sent with image requests
    /// to servers behind Cloudflare Bot Fight Mode. Set by DependencyContainer
    /// when configuring services for a CF-protected server.
    /// Thread-safe: only accessed from within the actor.
    private var cfCustomHeaders: [String: String]?

    /// The host of the CF-protected server, used to scope header injection
    /// to only requests targeting that server (not external image URLs).
    private var cfServerHost: String?

    /// Configures CF headers for image requests. Called by DependencyContainer.
    func configureCFHeaders(customHeaders: [String: String]?, serverHost: String?) {
        self.cfCustomHeaders = customHeaders
        self.cfServerHost = serverHost
    }

    // MARK: - Self-Signed Certificate Support

    /// Whether requests to the configured server host should bypass SSL validation.
    /// Set by DependencyContainer when `ServerConfig.allowSelfSignedCertificates` is true.
    private var allowSelfSignedCerts: Bool = false

    /// The server host scoped for self-signed cert bypass.
    /// Only requests targeting this host skip SSL validation — external URLs still use
    /// the system trust store so we don't weaken security for unrelated endpoints.
    private var selfSignedCertServerHost: String?

    /// Lazy custom URLSession that trusts self-signed certificates.
    /// Created once on first use and reused for all subsequent requests.
    /// Re-created when `configureSelfSignedCertSupport` is called with new settings.
    private var selfSignedSession: URLSession?

    /// Configures self-signed certificate support for image requests.
    /// Called by DependencyContainer when `ServerConfig.allowSelfSignedCertificates` changes.
    ///
    /// - Parameters:
    ///   - allowed: When `true`, image requests to `serverHost` will bypass SSL cert validation.
    ///   - serverHost: The server host (e.g. `"myserver.local"`) to scope the bypass to.
    func configureSelfSignedCertSupport(allowed: Bool, serverHost: String?) {
        self.allowSelfSignedCerts = allowed
        self.selfSignedCertServerHost = serverHost
        // Invalidate cached session so it's re-created with new settings on next use
        selfSignedSession?.invalidateAndCancel()
        selfSignedSession = nil
        logger.info("ImageCache: self-signed cert support \(allowed ? "enabled" : "disabled") for host \(serverHost ?? "none")")
    }

    /// Returns the URLSession to use for a given URL.
    /// Uses the self-signed-cert session when the URL targets the configured
    /// server host and `allowSelfSignedCerts` is enabled; otherwise uses `URLSession.shared`.
    private func session(for url: URL) -> URLSession {
        guard allowSelfSignedCerts,
              let targetHost = selfSignedCertServerHost,
              url.host?.lowercased() == targetHost.lowercased() else {
            return URLSession.shared
        }

        if let existing = selfSignedSession {
            return existing
        }

        let delegate = SelfSignedCertDelegate(serverHost: targetHost)
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        selfSignedSession = session
        return session
    }

    // MARK: - Init

    private init() {
        memoryCache.countLimit = memoryCacheLimit
        // Cost limit is now meaningful — costs reflect actual decoded bitmap bytes.
        // 150 MB allows ~400 fully decoded 108×108@3x RGBA images (108*108*4 ≈ 47 KB each).
        memoryCache.totalCostLimit = 150 * 1024 * 1024
        Task { await self.evictDiskCacheIfNeeded() }
    }

    // MARK: - Public API

    /// Returns a cached image for the given URL, checking memory first then disk.
    ///
    /// When loading from disk the image is promoted to the memory cache using
    /// the correct bitmap-byte cost so NSCache can evict accurately.
    ///
    /// - Parameter url: The image URL to look up.
    /// - Returns: The cached `UIImage`, or `nil` if not cached.
    func cachedImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Memory cache lookup
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }

        // Disk cache lookup — promote to memory with correct bitmap cost
        if let diskImage = loadFromDisk(key: key) {
            let cost = bitmapCost(for: diskImage)
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }

        return nil
    }

    /// Synchronous memory-only cache lookup — safe to call from any context.
    ///
    /// `NSCache` is thread-safe, so this can be called from `nonisolated` or
    /// synchronous contexts without awaiting the actor. Use this in SwiftUI
    /// view initializers to pre-populate state and avoid shimmer flashes when
    /// the image is already warm in memory.
    ///
    /// - Parameter url: The image URL to look up.
    /// - Returns: The cached `UIImage` from memory only, or `nil` if not in memory.
    /// Called from SwiftUI view `init` — always on the main actor.
    @MainActor func cachedImageSync(for url: URL) -> UIImage? {
        let key = cacheKeySync(for: url)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Loads an image from the given URL, using the cache if available.
    ///
    /// Deduplicates concurrent requests for the same URL. If a download is already
    /// in progress, callers share the same `Task`. Downloads are limited to
    /// `maxConcurrentDownloads` simultaneous connections; excess callers wait.
    ///
    /// Images are decoded at `targetPixelSize` (width and height) using ImageIO
    /// downsampling — a 2048×2048 favicon decoded for a 36pt@3x avatar becomes
    /// 108×108, ~360× less memory than full-resolution decoding.
    ///
    /// - Parameters:
    ///   - url: The image URL to load.
    ///   - authToken: Optional Bearer token for authenticated endpoints.
    ///   - customHeaders: Optional custom headers (e.g. Cloudflare User-Agent).
    ///   - targetPixelSize: Target pixel dimension for downsampling (0 = no downsampling).
    /// - Returns: The loaded `UIImage`, or `nil` on failure.
    func loadImage(
        from url: URL,
        authToken: String? = nil,
        customHeaders: [String: String]? = nil,
        targetPixelSize: Int = 0
    ) async -> UIImage? {
        let key = cacheKey(for: url)

        // Check caches first (no network needed)
        if let cached = cachedImage(for: url) {
            return cached
        }

        // Deduplicate in-flight requests for the same URL
        if let existingTask = activeTasks[key] {
            return await existingTask.value
        }

        // Capture actor state needed inside the Task (avoids re-entrancy captures)
        let cfHeaders = self.cfCustomHeaders
        let cfHost = self.cfServerHost
        let urlSession = self.session(for: url)

        let task = Task<UIImage?, Never> {
            // Acquire a download slot — suspends until < maxConcurrentDownloads are active
            await self.acquireDownloadSlot()
            defer { Task { self.releaseDownloadSlot() } }

            do {
                var request = URLRequest(url: url)
                // Bypass URLSession's built-in HTTP cache — we manage our own
                // disk + memory cache via ImageCacheService. URLSession's HTTP
                // cache can serve stale/failed responses for profile images
                // whose URL never changes after an avatar upload.
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let authToken, !authToken.isEmpty {
                    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                }
                var effectiveHeaders = customHeaders ?? [:]
                if effectiveHeaders.isEmpty,
                   let cfHeaders,
                   let cfHost,
                   url.host?.lowercased() == cfHost.lowercased() {
                    effectiveHeaders = cfHeaders
                }
                for (hKey, hValue) in effectiveHeaders {
                    request.setValue(hValue, forHTTPHeaderField: hKey)
                }

                let (data, response) = try await urlSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...399).contains(httpResponse.statusCode),
                      !data.isEmpty
                else {
                    if let httpResponse = response as? HTTPURLResponse {
                        self.logger.debug("Image load failed for \(url.lastPathComponent): status=\(httpResponse.statusCode)")
                    } else {
                        self.logger.debug("Image load failed for \(url.lastPathComponent): no HTTP response")
                    }
                    return nil
                }

                // Downsample to target pixel size if requested, otherwise decode normally
                let image: UIImage
                if targetPixelSize > 0,
                   let downsampled = Self.downsampledImage(data: data, maxPixelSize: targetPixelSize) {
                    image = downsampled
                } else if let fallback = UIImage(data: data), fallback.size.width > 0 {
                    image = fallback
                } else {
                    return nil
                }

                // Deduplicate: identical images share one UIImage instance in memory
                let canonical = self.deduplicatedImage(image)

                // Store in memory with accurate bitmap cost so NSCache evicts correctly
                let cost = self.bitmapCost(for: canonical)
                self.memoryCache.setObject(canonical, forKey: key as NSString, cost: cost)

                // Store raw (pre-downsample) data on disk for future sessions
                self.saveToDisk(data: data, key: key)

                return canonical
            } catch {
                self.logger.error("Image download failed for \(url): \(error.localizedDescription)")
                return nil
            }
        }

        activeTasks[key] = task
        let result = await task.value
        activeTasks.removeValue(forKey: key)

        return result
    }

    /// Prefetches images for the given URLs in the background.
    ///
    /// - Parameter urls: The image URLs to prefetch.
    func prefetch(urls: [URL]) {
        for url in urls {
            let key = cacheKey(for: url)
            guard memoryCache.object(forKey: key as NSString) == nil else { continue }

            Task {
                _ = await loadImage(from: url)
            }
        }
    }

    /// Prefetches authenticated images for the given URLs in parallel, up to `maxConcurrency`
    /// simultaneous downloads. Designed for model avatar endpoints that require a Bearer token.
    ///
    /// - Parameters:
    ///   - urls: The image URLs to prefetch (already-cached URLs are skipped instantly).
    ///   - authToken: Bearer token to attach to each request.
    ///   - maxConcurrency: Maximum simultaneous downloads (default: 6). Keeps the request
    ///     count reasonable so the server isn't flooded when 50+ models load at once.
    func prefetchWithAuth(urls: [URL], authToken: String?, maxConcurrency: Int = 6) {
        Task(priority: .userInitiated) {
            // Split into batches of `maxConcurrency` and fire them in parallel within each batch.
            let batches = stride(from: 0, to: urls.count, by: maxConcurrency).map {
                Array(urls[$0..<min($0 + maxConcurrency, urls.count)])
            }
            for batch in batches {
                await withTaskGroup(of: Void.self) { group in
                    for url in batch {
                        // Skip URLs already in memory — no network needed.
                        let key = self.cacheKey(for: url)
                        guard self.memoryCache.object(forKey: key as NSString) == nil else { continue }
                        group.addTask {
                            _ = await self.loadImage(from: url, authToken: authToken)
                        }
                    }
                }
            }
        }
    }

    /// Stores an image in both memory and disk caches.
    ///
    /// - Parameters:
    ///   - image: The image to cache.
    ///   - url: The URL key for the image.
    func store(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let cost = bitmapCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        if let data = image.jpegData(compressionQuality: 0.85) {
            saveToDisk(data: data, key: key)
        }
    }

    /// Evicts all images from memory and disk caches.
    func clearAll() {
        memoryCache.removeAllObjects()
        imageDeduplicationMap.removeAll()
        clearDiskCache()
        logger.info("Image cache cleared")
    }

    /// Evicts the cached image for a specific URL from both memory and disk.
    ///
    /// Used to invalidate model avatars when models are refreshed, ensuring
    /// admin-updated avatar images are re-fetched from the server.
    func evict(for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)
        if let directory = diskCacheDirectory {
            let fileURL = directory.appendingPathComponent(key)
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Evicts only the memory cache, preserving disk cache.
    func clearMemory() {
        memoryCache.removeAllObjects()
        imageDeduplicationMap.removeAll()
    }

    /// Evicts all cached profile images (user/model avatars) from both memory and disk.
    /// Call on app startup and logout/login to ensure fresh avatars.
    func evictProfileImages() {
        // Clear memory cache entirely — profile images reload quickly
        memoryCache.removeAllObjects()
        imageDeduplicationMap.removeAll()

        // Also remove profile images from disk cache
        guard let directory = diskCacheDirectory else { return }
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // We can't reverse the hash to check the URL, so clear the entire disk cache
            // on login/startup. This is acceptable since it only happens on explicit events.
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        logger.info("Profile image cache invalidated — will re-fetch on next access")
    }

    /// Whether this URL points to a user or model profile image.
    /// Matches: `/api/v1/users/{id}/profile/image` and `/api/v1/models/{id}/profile/image`
    private func isProfileImageURL(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/profile/image")
    }

    /// STORAGE FIX: Proactively runs disk eviction without requiring a save.
    /// Called by StorageManager on app launch and when entering background
    /// to ensure the cache stays under its size limit between sessions.
    func evictDiskCacheProactively() {
        evictDiskCacheIfNeeded()
    }

    // MARK: - Image Downsampling

    /// Decodes image data at a maximum pixel dimension using ImageIO, avoiding a full-resolution
    /// decode. A 2048×2048 image downsampled to 108px uses ~47 KB instead of ~16 MB in memory.
    ///
    /// - Parameters:
    ///   - data: Raw image data (PNG, JPEG, WebP, etc.)
    ///   - maxPixelSize: Maximum width or height in pixels for the thumbnail.
    /// - Returns: A downsampled `UIImage`, or `nil` if creation fails.
    static func downsampledImage(data: Data, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: thumbnail)
    }

    // MARK: - Cost Calculation

    /// Returns the actual decoded bitmap size in bytes for a UIImage.
    /// This is the correct value to use as NSCache cost — not compressed data size.
    ///
    /// For a 108×108 RGBA image: 108 × 108 × 4 = ~47 KB.
    /// For a 2048×2048 RGBA image (undownsampled): 2048 × 2048 × 4 = ~16 MB.
    private func bitmapCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            // Fallback: use pixel dimensions × 4 bytes/pixel
            let px = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
            return px * 4
        }
        // bytesPerRow already accounts for any alignment padding
        return cgImage.bytesPerRow * cgImage.height
    }

    // MARK: - Disk Cache

    private var diskCacheDirectory: URL? {
        fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func cacheKey(for url: URL) -> String {
        Self.computeCacheKey(for: url)
    }

    /// Computes the cache key without actor isolation — safe to call from any context.
    nonisolated private func cacheKeySync(for url: URL) -> String {
        Self.computeCacheKey(for: url)
    }

    /// Pure static hash function, callable from any isolation context.
    private static func computeCacheKey(for url: URL) -> String {
        // FNV-1a 128-bit equivalent: two independent 64-bit hashes combined.
        // Collision-resistant for URLs that differ only in query parameters.
        let urlString = url.absoluteString
        let data = Data(urlString.utf8)
        var h1 = UInt64(14695981039346656037) // FNV offset basis
        var h2 = UInt64(0xcbf29ce484222325)   // Secondary seed
        for byte in data {
            h1 ^= UInt64(byte)
            h1 &*= 1099511628211 // FNV prime
            h2 ^= UInt64(byte)
            h2 &*= 6364136223846793005
        }
        return String(h1, radix: 16) + String(h2, radix: 16)
    }

    private func saveToDisk(data: Data, key: String) {
        guard let directory = diskCacheDirectory else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(key)
            try data.write(to: fileURL, options: .atomic)
            // Evict oldest entries if disk cache exceeds size limit
            evictDiskCacheIfNeeded()
        } catch {
            logger.error("Failed to save image to disk: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk(key: String) -> UIImage? {
        guard let directory = diskCacheDirectory else { return nil }
        let fileURL = directory.appendingPathComponent(key)

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func clearDiskCache() {
        guard let directory = diskCacheDirectory else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Evicts oldest disk cache entries when total size exceeds `diskCacheSizeLimit`.
    /// Uses file modification dates for LRU ordering.
    private func evictDiskCacheIfNeeded() {
        guard let directory = diskCacheDirectory else { return }

        do {
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: .skipsHiddenFiles
            )

            // Gather file info
            var totalSize: Int = 0
            var fileInfos: [(url: URL, date: Date, size: Int)] = []

            for file in files {
                let values = try file.resourceValues(forKeys: resourceKeys)
                let size = values.fileSize ?? 0
                let date = values.contentModificationDate ?? .distantPast
                totalSize += size
                fileInfos.append((url: file, date: date, size: size))
            }

            // Only evict if over limit
            guard totalSize > diskCacheSizeLimit else { return }

            // Sort oldest first
            fileInfos.sort { $0.date < $1.date }

            // Delete oldest files until under limit
            for info in fileInfos {
                guard totalSize > diskCacheSizeLimit else { break }
                try? fileManager.removeItem(at: info.url)
                totalSize -= info.size
            }

            logger.info("Disk cache eviction: trimmed to \(totalSize) bytes")
        } catch {
            logger.error("Disk cache eviction failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Cached Async Image

/// A SwiftUI view that loads and displays an image with caching support.
///
/// Unlike `AsyncImage`, this uses ``ImageCacheService`` for persistent
/// caching across app sessions, reducing redundant network requests.
///
/// **Scroll debounce**: Waits 150 ms before starting a network fetch. Rows scrolled
/// past quickly cancel before the fetch begins — no wasted network requests.
///
/// **Target size**: Pass `targetPixelSize` to downsample images to the display size.
/// For a 36pt avatar on a 3× display, pass `targetPixelSize: 108`.
///
/// Usage:
/// ```swift
/// CachedAsyncImage(url: avatarURL, targetPixelSize: 108) { image in
///     image.resizable().aspectRatio(contentMode: .fill)
/// } placeholder: {
///     ProgressView()
/// }
/// ```
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Optional Bearer token for authenticated image endpoints.
    var authToken: String?
    /// Target pixel dimension for ImageIO downsampling (0 = no downsampling).
    /// Set to `Int(displayPoints * UIScreen.main.scale)` at the call site.
    var targetPixelSize: Int
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    /// Pre-populated synchronously from the memory cache so the view
    /// renders the cached image immediately on first layout — no shimmer flash.
    @State private var loadedImage: UIImage?

    init(
        url: URL?,
        authToken: String? = nil,
        targetPixelSize: Int = 0,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.authToken = authToken
        self.targetPixelSize = targetPixelSize
        self.content = content
        self.placeholder = placeholder
        // Synchronous memory-cache hit: pre-populate so SwiftUI renders the
        // image on the very first pass without a shimmer flash.
        if let url {
            _loadedImage = State(initialValue: ImageCacheService.shared.cachedImageSync(for: url))
        }
    }

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else {
                placeholder()
            }
        }
        // When the URL changes (e.g. switching selected model in the toolbar),
        // immediately update loadedImage from the memory cache (synchronous, zero-cost)
        // or nil it out so the placeholder shows while the new image fetches.
        .task(id: url) {
            // Synchronously check memory cache for the new URL first.
            if let newURL = url,
               let cached = ImageCacheService.shared.cachedImageSync(for: newURL) {
                loadedImage = cached
                return
            }
            // Not in memory — show placeholder and fetch from disk/network.
            loadedImage = nil

            // Scroll debounce: wait 150 ms before hitting disk/network.
            // If the row is scrolled past quickly the task is cancelled here,
            // saving a disk read or network request entirely.
            do {
                try await Task.sleep(nanoseconds: 150_000_000) // 150 ms
            } catch {
                return // Task was cancelled — row scrolled off screen
            }

            await fetchImage()
        }
    }

    /// Fetches the image from cache (disk) or network and populates `loadedImage`.
    private func fetchImage() async {
        guard let url else { return }
        let fresh = await ImageCacheService.shared.loadImage(
            from: url,
            authToken: authToken,
            targetPixelSize: targetPixelSize
        )
        if let fresh {
            loadedImage = fresh
        }
    }
}

// MARK: - Self-Signed Certificate Delegate

/// `URLSessionDelegate` that accepts self-signed TLS certificates for a specific server host.
///
/// Scoped to the configured host only — external URLs (e.g. Gravatar, CDN avatars) still
/// go through the system trust store so we don't weaken security globally.
///
/// Mirrors the `CertificateTrustDelegate` used by `NetworkManager` for API requests.
private final class SelfSignedCertDelegate: NSObject, URLSessionDelegate, Sendable {
    let serverHost: String

    init(serverHost: String) {
        self.serverHost = serverHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only bypass SSL for the configured server host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == serverHost.lowercased(),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
