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

    // MARK: - Public API

    /// Performs a full cleanup pass. Call on app launch and when entering background.
    /// This is the main entry point — it orchestrates all cleanup tasks.
    func performRoutineCleanup() {
        logger.info("Starting routine storage cleanup")

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

        // HuggingFace Hub cache (ML models)
        report["ML Models"] = Int64(diskSize(of: huggingFaceHubCacheDirectory))

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

    /// Returns the estimated size of downloaded ML models.
    func mlModelCacheSize() -> Int64 {
        Int64(diskSize(of: huggingFaceHubCacheDirectory))
    }

    /// Returns the on-disk size of the Parakeet ASR model files (without deleting).
    func parakeetASRModelSize() -> Int64 {
        var total: Int64 = 0
        total += modelFilesSize(matching: "parakeet-tdt")
        total += mlxAudioModelFilesSize(matching: "parakeet-tdt")
        return total
    }

    /// Returns the on-disk size of the MarvisTTS model files (without deleting).
    func marvisTTSModelSize() -> Int64 {
        var total: Int64 = 0
        total += modelFilesSize(matching: "marvis-tts")
        total += modelFilesSize(matching: "Marvis-AI")
        total += mlxAudioModelFilesSize(matching: "marvis")
        return total
    }

    /// Deletes all downloaded HuggingFace Hub ML model files (MarvisTTS + Parakeet ASR).
    /// Returns the number of bytes freed.
    @discardableResult
    func deleteAllMLModelFiles() -> Int64 {
        guard let dir = huggingFaceHubCacheDirectory else { return 0 }
        let size = Int64(diskSize(of: dir))
        try? fileManager.removeItem(at: dir)
        if size > 0 {
            logger.info("Deleted ML model files: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        return size
    }

    /// Deletes only MarvisTTS model files.
    /// Searches both the legacy "MarvisTTS" pattern and the mlx-audio-swift
    /// cache pattern ("marvis-tts", "Marvis-AI_marvis-tts") used by ModelUtils.
    @discardableResult
    func deleteMarvisTTSModelFiles() -> Int64 {
        var total: Int64 = 0
        total += deleteModelFiles(matching: "MarvisTTS")
        total += deleteModelFiles(matching: "marvis-tts")
        total += deleteModelFiles(matching: "Marvis-AI")
        total += deleteMLXAudioModelFiles(matching: "marvis")
        return total
    }

    /// Deletes Parakeet ASR model files.
    /// Searches the mlx-audio-swift cache pattern ("parakeet-tdt") used by ModelUtils.
    @discardableResult
    func deleteParakeetASRModelFiles() -> Int64 {
        var total: Int64 = 0
        total += deleteModelFiles(matching: "parakeet-tdt")
        total += deleteMLXAudioModelFiles(matching: "parakeet-tdt")
        return total
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

    /// Deletes model files from the mlx-audio-swift cache directory.
    /// mlx-audio-swift stores models under `{cachesDir}/huggingface/hub/mlx-audio/{repoId}`.
    private func deleteMLXAudioModelFiles(matching pattern: String) -> Int64 {
        guard let hubDir = huggingFaceHubCacheDirectory else { return 0 }

        // mlx-audio-swift uses: {huggingfaceDir}/hub/mlx-audio/{owner_reponame}/
        // huggingFaceHubCacheDirectory returns the "huggingface" dir, so we need hub/mlx-audio
        let mlxAudioDir = hubDir.appendingPathComponent("hub/mlx-audio", isDirectory: true)
        guard fileManager.fileExists(atPath: mlxAudioDir.path) else { return 0 }

        var totalFreed: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: mlxAudioDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            for item in contents {
                let name = item.lastPathComponent.lowercased()
                if name.contains(pattern.lowercased()) {
                    let size = Int64(diskSize(of: item))
                    try? fileManager.removeItem(at: item)
                    totalFreed += size
                }
            }
        } catch {
            logger.error("Failed to delete mlx-audio \(pattern) files: \(error.localizedDescription)")
        }

        if totalFreed > 0 {
            logger.info("Deleted mlx-audio \(pattern) files: \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file))")
        }

        return totalFreed
    }

    /// Returns the size of model files matching a name pattern without deleting them.
    private func modelFilesSize(matching pattern: String) -> Int64 {
        guard let hubDir = huggingFaceHubCacheDirectory else { return 0 }
        guard fileManager.fileExists(atPath: hubDir.path) else { return 0 }
        var total: Int64 = 0
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: hubDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            for item in contents where item.lastPathComponent.lowercased().contains(pattern.lowercased()) {
                total += Int64(diskSize(of: item))
            }
        } catch {}
        return total
    }

    /// Returns the size of mlx-audio model files matching a name pattern without deleting them.
    private func mlxAudioModelFilesSize(matching pattern: String) -> Int64 {
        guard let hubDir = huggingFaceHubCacheDirectory else { return 0 }
        let mlxAudioDir = hubDir.appendingPathComponent("hub/mlx-audio", isDirectory: true)
        guard fileManager.fileExists(atPath: mlxAudioDir.path) else { return 0 }
        var total: Int64 = 0
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: mlxAudioDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            for item in contents where item.lastPathComponent.lowercased().contains(pattern.lowercased()) {
                total += Int64(diskSize(of: item))
            }
        } catch {}
        return total
    }

    /// Deletes model files matching a name pattern in the HuggingFace cache.
    private func deleteModelFiles(matching pattern: String) -> Int64 {
        guard let hubDir = huggingFaceHubCacheDirectory else { return 0 }
        guard fileManager.fileExists(atPath: hubDir.path) else { return 0 }

        var totalFreed: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: hubDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            for item in contents {
                let name = item.lastPathComponent.lowercased()
                if name.contains(pattern.lowercased()) {
                    let size = Int64(diskSize(of: item))
                    try? fileManager.removeItem(at: item)
                    totalFreed += size
                }
            }
        } catch {
            logger.error("Failed to delete \(pattern) model files: \(error.localizedDescription)")
        }

        if totalFreed > 0 {
            logger.info("Deleted \(pattern) files: \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file))")
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

    /// HuggingFace Hub stores downloaded models in the app's caches or
    /// application support directory. Check common locations.
    private var huggingFaceHubCacheDirectory: URL? {
        // HuggingFace Hub Swift typically uses:
        // ~/Library/Caches/huggingface/hub/ or
        // ~/Library/Application Support/huggingface/hub/
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        // Check caches first (more common)
        if let dir = cacheDir?.appendingPathComponent("huggingface", isDirectory: true),
           fileManager.fileExists(atPath: dir.path) {
            return dir
        }

        // Check application support
        if let dir = appSupportDir?.appendingPathComponent("huggingface", isDirectory: true),
           fileManager.fileExists(atPath: dir.path) {
            return dir
        }

        // Also check for .cache/huggingface pattern
        if let dir = cacheDir?.appendingPathComponent(".cache/huggingface", isDirectory: true),
           fileManager.fileExists(atPath: dir.path) {
            return dir
        }

        // Check home directory patterns
        let homeDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.deletingLastPathComponent()
        if let dir = homeDir?.appendingPathComponent(".cache/huggingface", isDirectory: true),
           fileManager.fileExists(atPath: dir.path) {
            return dir
        }

        return cacheDir?.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Calculates the total disk size of a directory (recursive).
    private func diskSize(of directory: URL?) -> Int {
        guard let directory else { return 0 }
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }

        var totalSize = 0
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
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
