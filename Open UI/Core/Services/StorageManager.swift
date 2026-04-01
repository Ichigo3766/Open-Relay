import Foundation
import os.log
import UIKit

/// Central storage management service that automatically maintains a small
/// disk footprint. Handles cleanup of temporary files, upload caches,
/// orphaned recordings, ML model files, and provides disk usage reporting.
///
/// ## Automatic Behavior
/// - Runs cleanup on app launch
/// - Runs cleanup when entering background
/// - Responds to memory warnings
/// - Requires zero user intervention
///
/// ## Storage Locations Managed
/// - `tmp/file_cache/` — uploaded file previews (Issue #2)
/// - `tmp/voice_note_*` — orphaned audio recordings (Issue #10)
/// - `Library/Caches/ImageCache/` — disk image cache (Issue #12)
/// - `URLCache.shared` — HTTP response cache (Issue #1)
/// - HuggingFace Hub model caches (Issues #3, #4)
final class StorageManager: @unchecked Sendable {

    static let shared = StorageManager()

    private let logger = Logger(subsystem: "com.openui", category: "Storage")
    private let fileManager = FileManager.default

    /// Maximum age for files in the upload cache (24 hours).
    private let uploadCacheMaxAge: TimeInterval = 24 * 60 * 60

    /// Maximum age for orphaned temp files (1 hour).
    private let tempFileMaxAge: TimeInterval = 60 * 60

    /// Maximum total size for the file upload cache (50 MB).
    private let uploadCacheSizeLimit: Int = 50 * 1024 * 1024

    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        // Listen for memory warnings
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Model Cache Location

    /// The canonical directory where all on-device ML models (MarvisTTS, Qwen3 ASR)
    /// are stored. Lives in `Documents/Models` so it is visible and fully deletable
    /// via the Files app. Pass `HubCache(location: .fixed(directory: StorageManager.modelCacheDirectory))`
    /// to any `fromPretrained` call.
    static var modelCacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Hub Cache Cleanup

    /// Deletes the HuggingFace Hub's internal `models--*` blob caches from Documents/Models.
    ///
    /// Background: When mlx-audio-swift downloads a model via `HubClient.downloadSnapshot()`,
    /// the HuggingFace Hub library maintains a Git-LFS-style cache alongside the working copy:
    ///
    ///   Documents/Models/
    ///   ├── mlx-audio/
    ///   │   └── Marvis-AI_marvis-tts-250m-v0.2-MLX-8bit/   ← working copy (what the app reads)
    ///   │       ├── model.safetensors  (665 MB)
    ///   │       └── ...
    ///   └── models--Marvis-AI--marvis-tts-250m-v0.2-MLX-8bit/  ← Hub's internal cache (duplicate!)
    ///       ├── blobs/  (the same 665 MB file lives here too)
    ///       ├── refs/
    ///       └── snapshots/
    ///
    /// The `models--*` folders are never read by the app after download — they exist only for
    /// the Hub library's version-tracking. Deleting them is safe and reclaims significant storage.
    ///
    /// - Returns: Bytes freed.
    @discardableResult
    func cleanupHubCache() -> Int64 {
        let dir = StorageManager.modelCacheDirectory
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }

        var totalFreed: Int64 = 0
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            for item in contents {
                let name = item.lastPathComponent
                // Only delete the Hub's internal cache folders (models--*), never mlx-audio/
                guard name.hasPrefix("models--") else { continue }
                let size = Int64(diskSize(of: item))
                try? fileManager.removeItem(at: item)
                totalFreed += size
                logger.info("Deleted Hub blob cache: \(name) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            }
        } catch {
            logger.error("Failed to clean hub cache: \(error.localizedDescription)")
        }

        if totalFreed > 0 {
            logger.info("Hub cache cleanup freed \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file))")
        }
        return totalFreed
    }

    /// One-time migration that cleans up:
    ///   1. All `models--*` Hub blob cache folders (duplicate model data).
    ///   2. Legacy Parakeet STT model files (replaced by Qwen3 ASR).
    ///   3. Legacy Moshi model files (no longer used).
    ///
    /// Runs once per device, keyed by `storage.hubCacheMigration.v1`. Safe to call on every
    /// app launch — it's a no-op after the first run.
    func runHubCacheMigrationIfNeeded() {
        let migrationKey = "storage.hubCacheMigration.v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        Task.detached(priority: .utility) { [self] in
            var totalFreed: Int64 = 0

            // 1. Delete all Hub blob cache dirs (models--*)
            totalFreed += await self.cleanupHubCache()

            // 2. Delete legacy Parakeet STT model (replaced by Qwen3 ASR)
            totalFreed += await self.deleteModelDirs(patterns: ["parakeet-tdt"])

            // 3. Delete legacy Moshi model files
            totalFreed += await self.deleteModelDirs(patterns: ["moshiko", "moshi"])

            let freedSnapshot = totalFreed
            await MainActor.run {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if freedSnapshot > 0 {
                    self.logger.info("Hub cache migration freed \(ByteCountFormatter.string(fromByteCount: freedSnapshot, countStyle: .file))")
                } else {
                    self.logger.info("Hub cache migration: nothing to clean")
                }
            }
        }
    }

    // MARK: - Public API

    /// Performs a full cleanup pass. Call on app launch and when entering background.
    /// This is the main entry point — it orchestrates all cleanup tasks.
    func performRoutineCleanup() {
        logger.info("Starting routine storage cleanup")

        // Run one-time migration (deletes Hub blob caches, legacy models). No-op after first run.
        runHubCacheMigrationIfNeeded()

        // Run cleanup on a background queue to avoid blocking main thread
        Task.detached(priority: .utility) { [self] in
            let freed = await self.cleanupAll()
            await MainActor.run {
                if freed > 0 {
                    self.logger.info("Routine cleanup freed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file))")
                } else {
                    self.logger.info("Routine cleanup: nothing to clean")
                }
            }
        }
    }

    /// Performs aggressive cleanup when memory is low.
    func handleMemoryWarning() {
        logger.warning("Memory warning — performing aggressive cleanup")

        // Clear all in-memory caches
        Task {
            await ImageCacheService.shared.clearMemory()
        }

        // Clear URLSession shared cache
        URLCache.shared.removeAllCachedResponses()

        // Run disk cleanup
        performRoutineCleanup()
    }

    /// Nuclear option — clears ALL user data and caches.
    /// Used on logout and server switch.
    func clearAllUserData() {
        logger.info("Clearing all user data and caches")

        // 1. Clear URLSession caches
        URLCache.shared.removeAllCachedResponses()

        // 2. Clear image cache (memory + disk)
        Task {
            await ImageCacheService.shared.clearAll()
        }

        // 3. Clear file upload cache
        clearFileUploadCache()

        // 4. Clear all temp files
        clearAllTempFiles()

        // 5. Clear notes from UserDefaults
        UserDefaults.standard.removeObject(forKey: "com.openui.notes")

        // 6. Clear shared data
        if let defaults = UserDefaults(suiteName: SharedDataService.appGroupId) {
            for key in ["recent_conversations", "recent_notes", "server_url",
                        "is_authenticated", "user_name", "last_active_conversation_id"] {
                defaults.removeObject(forKey: key)
            }
        }

        logger.info("All user data cleared")
    }

    // MARK: - Disk Usage Reporting

    /// Returns a breakdown of storage usage by category.
    func getDiskUsageReport() async -> [String: Int64] {
        var report: [String: Int64] = [:]

        // Image cache
        report["Image Cache"] = Int64(diskSize(of: imageCacheDirectory))

        // File upload cache
        report["Upload Cache"] = Int64(diskSize(of: fileUploadCacheDirectory))

        // Temp directory
        report["Temp Files"] = Int64(diskSize(of: fileManager.temporaryDirectory))

        // URLCache
        report["HTTP Cache"] = Int64(URLCache.shared.currentDiskUsage)

        // ML model cache (Documents/Models)
        report["ML Models"] = Int64(diskSize(of: StorageManager.modelCacheDirectory))

        // Total app size (for reference)
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            report["App Support"] = Int64(diskSize(of: appSupport))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            report["Caches Dir"] = Int64(diskSize(of: caches))
        }

        return report
    }

    /// Returns total disk usage in bytes across all managed locations.
    func totalManagedDiskUsage() async -> Int64 {
        let report = await getDiskUsageReport()
        return report.values.reduce(0, +)
    }

    // MARK: - Full Storage Enumeration (for Storage Settings view)

    /// Represents a single file or folder entry for the storage browser UI.
    struct StorageEntry: Identifiable, Sendable {
        let id: String
        let url: URL
        let name: String
        let size: Int64          // Total size (recursive for directories)
        let isDirectory: Bool
        let depth: Int           // 0 = root-level item in the scanned directory
        var children: [StorageEntry]?

        /// Human-readable formatted size string.
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        /// SF Symbol name appropriate for the entry type.
        var systemImage: String {
            if isDirectory { return "folder.fill" }
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "safetensors", "gguf", "bin", "pt", "pth": return "cpu"
            case "json":                                      return "doc.text"
            case "txt", "md":                                 return "text.document"
            case "jpg", "jpeg", "png", "gif", "webp":        return "photo"
            case "m4a", "wav", "mp3":                         return "waveform"
            case "mp4", "mov":                                return "video"
            case "zip", "tar", "gz":                          return "archivebox"
            case "sqlite", "db":                              return "cylinder.split.1x2"
            default:                                          return "doc"
            }
        }
    }

    /// Recursively scans a directory and returns a flat list of top-level
    /// `StorageEntry` items, each with their total recursive sizes.
    /// Directories get a `children` array containing their contents.
    nonisolated func enumerateDirectory(_ url: URL, depth: Int = 0) -> [StorageEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }

        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .totalFileSizeKey],
                options: .skipsHiddenFiles
            )

            var entries: [StorageEntry] = []
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir {
                    let dirSize = Int64(diskSize(of: item, using: fm))
                    let children = enumerateDirectory(item, depth: depth + 1)
                    entries.append(StorageEntry(
                        id: item.path,
                        url: item,
                        name: item.lastPathComponent,
                        size: dirSize,
                        isDirectory: true,
                        depth: depth,
                        children: children
                    ))
                } else {
                    let fileSize: Int64
                    if let fSize = try? item.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize {
                        fileSize = Int64(fSize)
                    } else if let fSize = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        fileSize = Int64(fSize)
                    } else {
                        fileSize = 0
                    }
                    entries.append(StorageEntry(
                        id: item.path,
                        url: item,
                        name: item.lastPathComponent,
                        size: fileSize,
                        isDirectory: false,
                        depth: depth,
                        children: nil
                    ))
                }
            }

            // Sort: directories first, then by size descending
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.size > $1.size
            }
        } catch {
            logger.error("Failed to enumerate directory \(url.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }

    /// Returns all storage locations the app writes to, as named root entries.
    func allStorageLocations() -> [(label: String, icon: String, color: String, url: URL)] {
        var locations: [(label: String, icon: String, color: String, url: URL)] = []

        // Documents directory (user-visible in Files app)
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            locations.append((label: "Documents", icon: "folder.fill", color: "blue", url: docs))
        }

        // Library/Application Support (Core Data, etc.)
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            locations.append((label: "Application Support", icon: "internaldrive", color: "purple", url: appSupport))
        }

        // Library/Caches (image cache, HTTP cache on disk)
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            locations.append((label: "Caches", icon: "cylinder.split.1x2", color: "orange", url: caches))
        }

        // Temporary directory
        locations.append((label: "Temporary Files", icon: "clock", color: "gray", url: fileManager.temporaryDirectory))

        return locations
    }

    /// Safely deletes a file or directory at the given URL. Returns bytes freed.
    @discardableResult
    func deleteItem(at url: URL) -> Int64 {
        let size = Int64(diskSize(of: url))
        // Check it's file size if not a directory
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let actualSize: Int64
        if isDir {
            actualSize = size
        } else {
            actualSize = (try? Int64(url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize ?? 0)) ?? size
        }

        do {
            try fileManager.removeItem(at: url)
            logger.info("Deleted item: \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: actualSize, countStyle: .file)))")
            return actualSize
        } catch {
            logger.error("Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            return 0
        }
    }

    /// Returns the total size of the full Documents directory.
    nonisolated func documentDirectorySize() -> Int64 {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        return Int64(diskSize(of: docs, using: fm))
    }

    /// Returns the total size of the Library/Application Support directory.
    nonisolated func appSupportDirectorySize() -> Int64 {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        return Int64(diskSize(of: appSupport, using: fm))
    }

    /// Returns the total size of the Library/Caches directory.
    nonisolated func cacheDirectorySize() -> Int64 {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        return Int64(diskSize(of: caches, using: fm))
    }

    /// Returns the total size of the Temporary directory.
    nonisolated func tempDirectorySize() -> Int64 {
        let fm = FileManager.default
        return Int64(diskSize(of: fm.temporaryDirectory, using: fm))
    }

    /// Clears all files from the app's tmp/ directory. Returns bytes freed.
    @discardableResult
    func clearTempDirectory() -> Int64 {
        let tmp = fileManager.temporaryDirectory
        let before = Int64(diskSize(of: tmp))
        let items = (try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for item in items {
            try? fileManager.removeItem(at: item)
        }
        let after = Int64(diskSize(of: tmp))
        return max(0, before - after)
    }

    @discardableResult
    func clearCachesDirectory() -> Int64 {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let freed = Int64(diskSize(of: caches))
        if let items = try? fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for item in items { try? fileManager.removeItem(at: item) }
        }
        URLCache.shared.removeAllCachedResponses()
        if freed > 0 {
            logger.info("Cleared Caches directory: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        }
        return freed
    }

    // MARK: - File Upload Cache (Issue #2)

    /// Clears the entire file upload cache directory.
    func clearFileUploadCache() {
        guard let dir = fileUploadCacheDirectory else { return }
        let freed = diskSize(of: dir)
        try? fileManager.removeItem(at: dir)
        if freed > 0 {
            logger.info("Cleared file upload cache: \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file))")
        }
    }

    /// Removes stale entries from the file upload cache based on age and size.
    private func pruneFileUploadCache() -> Int {
        guard let dir = fileUploadCacheDirectory else { return 0 }
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }

        var totalFreed = 0
        let now = Date()

        do {
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let files = try fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Array(resourceKeys),
                options: .skipsHiddenFiles
            )

            var totalSize = 0
            var fileInfos: [(url: URL, date: Date, size: Int)] = []

            for file in files {
                let values = try file.resourceValues(forKeys: resourceKeys)
                let size = values.fileSize ?? 0
                let date = values.contentModificationDate ?? .distantPast
                totalSize += size

                // Remove files older than max age
                if now.timeIntervalSince(date) > uploadCacheMaxAge {
                    try? fileManager.removeItem(at: file)
                    totalFreed += size
                    totalSize -= size
                } else {
                    fileInfos.append((url: file, date: date, size: size))
                }
            }

            // If still over size limit, evict oldest first
            if totalSize > uploadCacheSizeLimit {
                fileInfos.sort { $0.date < $1.date }
                for info in fileInfos {
                    guard totalSize > uploadCacheSizeLimit else { break }
                    try? fileManager.removeItem(at: info.url)
                    totalFreed += info.size
                    totalSize -= info.size
                }
            }
        } catch {
            logger.error("Failed to prune upload cache: \(error.localizedDescription)")
        }

        return totalFreed
    }

    // MARK: - Temp File Cleanup (Issue #10)

    /// Removes orphaned temporary files (audio recordings, ASR processing, etc.)
    private func cleanOrphanedTempFiles() -> Int {
        let tempDir = fileManager.temporaryDirectory
        var totalFreed = 0
        let now = Date()

        do {
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let files = try fileManager.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: Array(resourceKeys),
                options: .skipsHiddenFiles
            )

            for file in files {
                let fileName = file.lastPathComponent

                // Only clean known temporary file patterns
                let isOrphanedAudio = fileName.hasPrefix("voice_note_") && fileName.hasSuffix(".m4a")
                let isASRTemp = fileName.contains("_") && (fileName.hasSuffix(".m4a") || fileName.hasSuffix(".wav") || fileName.hasSuffix(".mp3"))
                let isStaleCache = fileName == "file_cache" // Directory — handled by pruneFileUploadCache

                guard isOrphanedAudio || isASRTemp else { continue }
                guard !isStaleCache else { continue }

                let values = try file.resourceValues(forKeys: resourceKeys)
                let date = values.contentModificationDate ?? .distantPast
                let size = values.fileSize ?? 0

                // Only clean files older than max age
                if now.timeIntervalSince(date) > tempFileMaxAge {
                    try? fileManager.removeItem(at: file)
                    totalFreed += size
                }
            }
        } catch {
            logger.error("Failed to clean temp files: \(error.localizedDescription)")
        }

        return totalFreed
    }

    /// Removes all temporary files (aggressive cleanup).
    private func clearAllTempFiles() {
        let tempDir = fileManager.temporaryDirectory
        do {
            let files = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        } catch {
            logger.error("Failed to clear temp files: \(error.localizedDescription)")
        }
    }

    // MARK: - ML Model Cache (Issues #3, #4)

    /// Returns the estimated size of all downloaded ML models in Documents/Models.
    func mlModelCacheSize() -> Int64 {
        Int64(diskSize(of: StorageManager.modelCacheDirectory))
    }

    /// Returns the on-disk size of the ASR model files (Qwen3-ASR + legacy Parakeet).
    func asrModelSize() -> Int64 {
        modelSize(patterns: ["Qwen3-ASR", "parakeet-tdt"])
    }

    /// Returns the on-disk size of the MarvisTTS model files.
    func marvisTTSModelSize() -> Int64 {
        modelSize(patterns: ["marvis-tts", "Marvis-AI", "MarvisTTS"])
    }

    /// Deletes all downloaded ML model files from Documents/Models.
    @discardableResult
    func deleteAllMLModelFiles() -> Int64 {
        let dir = StorageManager.modelCacheDirectory
        let size = Int64(diskSize(of: dir))
        // Remove contents but keep the directory itself
        if let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items { try? fileManager.removeItem(at: item) }
        }
        if size > 0 {
            logger.info("Deleted all ML model files: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        return size
    }

    /// Deletes only MarvisTTS model files from Documents/Models.
    @discardableResult
    func deleteMarvisTTSModelFiles() -> Int64 {
        let freed = deleteModelDirs(patterns: ["marvis-tts", "Marvis-AI", "MarvisTTS"])
        if freed > 0 {
            logger.info("Deleted MarvisTTS model files: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        }
        return freed
    }

    /// Deletes ASR model files (Qwen3-ASR + legacy Parakeet) from Documents/Models.
    @discardableResult
    func deleteASRModelFiles() -> Int64 {
        let freed = deleteModelDirs(patterns: ["Qwen3-ASR", "parakeet-tdt"])
        if freed > 0 {
            logger.info("Deleted ASR model files: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        }
        return freed
    }

    // MARK: - Model Dir Helpers

    /// Searches `Documents/Models/` AND `Documents/Models/mlx-audio/` for directories
    /// matching any of the given patterns (case-insensitive substring match on folder name).
    /// This is needed because mlx-audio-swift stores downloaded model weights inside the
    /// `mlx-audio/` subdirectory, e.g.:
    ///   Documents/Models/mlx-audio/Marvis-AI_marvis-tts-250m-v0.2-MLX-8bit/
    private func modelSize(patterns: [String]) -> Int64 {
        let root = StorageManager.modelCacheDirectory
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        // Directories to scan: the root itself, plus the mlx-audio/ subdirectory
        var scanDirs: [URL] = [root]
        let mlxAudio = root.appendingPathComponent("mlx-audio", isDirectory: true)
        if fileManager.fileExists(atPath: mlxAudio.path) { scanDirs.append(mlxAudio) }

        var total: Int64 = 0
        for dir in scanDirs {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            for item in contents {
                let name = item.lastPathComponent.lowercased()
                if patterns.contains(where: { name.contains($0.lowercased()) }) {
                    total += Int64(diskSize(of: item))
                }
            }
        }
        return total
    }

    /// Deletes directories matching any of the given patterns from both
    /// `Documents/Models/` and `Documents/Models/mlx-audio/`.
    private func deleteModelDirs(patterns: [String]) -> Int64 {
        let root = StorageManager.modelCacheDirectory
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        var scanDirs: [URL] = [root]
        let mlxAudio = root.appendingPathComponent("mlx-audio", isDirectory: true)
        if fileManager.fileExists(atPath: mlxAudio.path) { scanDirs.append(mlxAudio) }

        var totalFreed: Int64 = 0
        for dir in scanDirs {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            for item in contents {
                let name = item.lastPathComponent.lowercased()
                if patterns.contains(where: { name.contains($0.lowercased()) }) {
                    let size = Int64(diskSize(of: item))
                    do {
                        try fileManager.removeItem(at: item)
                        totalFreed += size
                    } catch {
                        logger.error("Failed to delete model dir \(item.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        return totalFreed
    }

    // MARK: - HTTP Cache (Issue #1)

    /// Purges the shared URLCache. Called once on startup and on logout.
    func purgeHTTPCache() {
        let size = URLCache.shared.currentDiskUsage
        URLCache.shared.removeAllCachedResponses()
        if size > 0 {
            logger.info("Purged HTTP cache: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
    }

    // MARK: - Private Helpers

    /// Runs all cleanup tasks and returns total bytes freed.
    private func cleanupAll() async -> Int {
        var totalFreed = 0

        // 1. Prune file upload cache
        totalFreed += pruneFileUploadCache()

        // 2. Clean orphaned temp files
        totalFreed += cleanOrphanedTempFiles()

        // 3. Trigger proactive image cache eviction
        await ImageCacheService.shared.evictDiskCacheProactively()

        // 4. Purge HTTP cache on first launch (one-time)
        let hasCleanedHTTPCache = UserDefaults.standard.bool(forKey: "storage.httpCacheCleaned.v1")
        if !hasCleanedHTTPCache {
            let httpCacheSize = URLCache.shared.currentDiskUsage
            URLCache.shared.removeAllCachedResponses()
            totalFreed += httpCacheSize
            UserDefaults.standard.set(true, forKey: "storage.httpCacheCleaned.v1")
        }

        return totalFreed
    }

    // MARK: - Directory Paths

    private var fileUploadCacheDirectory: URL? {
        let dir = fileManager.temporaryDirectory.appendingPathComponent("file_cache", isDirectory: true)
        return dir
    }

    private var imageCacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    /// Calculates the total disk size of a directory (recursive).
    private func diskSize(of directory: URL?) -> Int {
        diskSize(of: directory, using: fileManager)
    }

    /// Nonisolated overload — accepts an explicit FileManager so it can be called
    /// from `nonisolated` methods without touching the actor-isolated `self.fileManager`.
    private nonisolated func diskSize(of directory: URL?, using fm: FileManager) -> Int {
        guard let directory else { return 0 }
        guard fm.fileExists(atPath: directory.path) else { return 0 }

        var totalSize = 0
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            if values.isDirectory != true {
                totalSize += values.fileSize ?? 0
            }
        }

        return totalSize
    }
}
