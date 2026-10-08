import Foundation
import os

/// Remembers which chats were created **on this device** (new chat, fork, clone).
///
/// `ExternalActivityNotifier` uses this to tell "a chat I started here" apart from
/// "a chat that appeared from somewhere else" (an automation, the web UI, another
/// device), so this device never notifies the user about its own chats.
///
/// Thread-safe and callable from any isolation domain. Persisted to UserDefaults so
/// the information survives a relaunch (e.g. a background launch after the app was
/// terminated). Entries expire after 7 days and the list is capped.
nonisolated enum LocalChatOrigin {

    private static let storageKey = "extNotif.localChatIds"
    private static let maxEntries = 300
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let lock = OSAllocatedUnfairLock()

    /// Records that `id` was created by this device.
    static func mark(_ id: String) {
        guard !id.isEmpty else { return }
        lock.withLock {
            var entries = load()
            entries[id] = Date().timeIntervalSince1970
            let cutoff = Date().timeIntervalSince1970 - maxAge
            entries = entries.filter { $0.value >= cutoff }
            if entries.count > maxEntries {
                let keep = entries.sorted { $0.value > $1.value }.prefix(maxEntries)
                entries = Dictionary(keep.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            }
            UserDefaults.standard.set(entries, forKey: storageKey)
        }
    }

    /// Whether `id` was created by this device.
    static func contains(_ id: String) -> Bool {
        lock.withLock { load()[id] != nil }
    }

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
    }
}
