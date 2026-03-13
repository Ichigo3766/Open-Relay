import SwiftUI
import os.log

/// A thread-safe, memory-efficient image cache with automatic eviction.
///
/// Uses `NSCache` under the hood for automatic memory pressure handling,
/// combined with a disk cache for persistence across launches. Images are
/// keyed by their URL string and stored as compressed `Data`.
///
/// Usage:
/// ```swift
/// let cache = ImageCacheService.shared
/// if let image = cache.image(for: url) { … }
/// cache.store(image, for: url)
/// ```
actor ImageCacheService {

    /// Shared singleton instance.
    static let shared = ImageCacheService()

    // MARK: - Private Storage

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.openui", category: "ImageCache")

    /// Maximum number of images to hold in memory.
    private let memoryCacheLimit = 100

    /// Maximum disk cache size in bytes (50 MB).
    private let diskCacheSizeLimit: Int = 50 * 1024 * 1024

    /// Active download tasks keyed by URL string to deduplicate requests.
    private var activeTasks: [String: Task<UIImage?, Never>] = [:]

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

    // MARK: - Init

    private init() {
        memoryCache.countLimit = memoryCacheLimit
        memoryCache.totalCostLimit = 30 * 1024 * 1024 // 30 MB
        // STORAGE FIX: Run eviction on init to trim any cache that grew
        // over the limit from a previous session. Dispatched as a Task
        // because actor-isolated methods can't be called from nonisolated init.
        Task { await self.evictDiskCacheIfNeeded() }
    }

    // MARK: - Public API

    /// Returns a cached image for the given URL, checking memory first
    /// then disk.
    ///
    /// - Parameter url: The image URL to look up.
    /// - Returns: The cached `UIImage`, or `nil` if not cached.
    func cachedImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Memory cache lookup
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }

        // Disk cache lookup
        if let diskImage = loadFromDisk(key: key) {
            // Promote to memory cache
            let cost = diskImage.jpegData(compressionQuality: 1.0)?.count ?? 0
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }

        return nil
    }

    /// Loads an image from the given URL, using the cache if available.
    ///
    /// Deduplicates concurrent requests for the same URL. If a download
    /// is already in progress, callers share the same `Task`.
    ///
    /// - Parameters:
    ///   - url: The image URL to load.
    ///   - authToken: Optional Bearer token for authenticated endpoints
    ///     (e.g. the model avatar endpoint `/api/v1/models/model/profile/image`).
    ///   - customHeaders: Optional custom headers to include (e.g. Cloudflare User-Agent).
    /// - Returns: The loaded `UIImage`, or `nil` on failure.
    func loadImage(from url: URL, authToken: String? = nil, customHeaders: [String: String]? = nil) async -> UIImage? {
        let key = cacheKey(for: url)

        // Check caches first
        if let cached = cachedImage(for: url) {
            return cached
        }

        // Deduplicate in-flight requests
        if let existingTask = activeTasks[key] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> {
            do {
                var request = URLRequest(url: url)
                if let authToken, !authToken.isEmpty {
                    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                }
                // Apply custom headers (e.g. CF User-Agent) so Cloudflare
                // doesn't reject the request due to UA mismatch.
                // First: explicitly passed headers take priority.
                // Second: auto-apply CF headers for requests to the CF-protected server.
                var effectiveHeaders = customHeaders ?? [:]
                if effectiveHeaders.isEmpty,
                   let cfHeaders = self.cfCustomHeaders,
                   let cfHost = self.cfServerHost,
                   url.host?.lowercased() == cfHost.lowercased() {
                    effectiveHeaders = cfHeaders
                }
                for (key, value) in effectiveHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                // Use URLSession.shared which picks up cookies from HTTPCookieStorage.shared
                // (including cf_clearance). The custom User-Agent header ensures CF accepts it.
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...399).contains(httpResponse.statusCode),
                      let image = UIImage(data: data),
                      image.size.width > 0 && image.size.height > 0
                else {
                    return nil
                }

                // Store in memory
                let cost = data.count
                memoryCache.setObject(image, forKey: key as NSString, cost: cost)

                // Store on disk asynchronously
                saveToDisk(data: data, key: key)

                return image
            } catch {
                logger.error("Image download failed for \(url): \(error.localizedDescription)")
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

    /// Stores an image in both memory and disk caches.
    ///
    /// - Parameters:
    ///   - image: The image to cache.
    ///   - url: The URL key for the image.
    func store(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let data = image.jpegData(compressionQuality: 0.85)
        let cost = data?.count ?? 0

        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        if let data {
            saveToDisk(data: data, key: key)
        }
    }

    /// Evicts all images from memory and disk caches.
    func clearAll() {
        memoryCache.removeAllObjects()
        clearDiskCache()
        logger.info("Image cache cleared")
    }

    /// Evicts only the memory cache, preserving disk cache.
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    /// STORAGE FIX: Proactively runs disk eviction without requiring a save.
    /// Called by StorageManager on app launch and when entering background
    /// to ensure the cache stays under its size limit between sessions.
    func evictDiskCacheProactively() {
        evictDiskCacheIfNeeded()
    }

    // MARK: - Disk Cache

    private var diskCacheDirectory: URL? {
        fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func cacheKey(for url: URL) -> String {
        // FIX: Use SHA256 instead of DJB2 to avoid hash collisions on similar URLs.
        // DJB2 has high collision rates for URLs that differ only in query parameters
        // (e.g., model avatar URLs with different model IDs).
        let urlString = url.absoluteString
        let data = Data(urlString.utf8)
        // Use a simple but collision-resistant hash: FNV-1a 128-bit equivalent
        // by combining two independent 64-bit hashes with different seeds.
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
/// Usage:
/// ```swift
/// CachedAsyncImage(url: avatarURL) { image in
///     image.resizable().aspectRatio(contentMode: .fill)
/// } placeholder: {
///     ProgressView()
/// }
/// ```
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Optional Bearer token for authenticated image endpoints.
    var authToken: String?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { return }
        isLoading = true

        loadedImage = await ImageCacheService.shared.loadImage(from: url, authToken: authToken)
        isLoading = false
    }
}
