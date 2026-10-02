import Foundation
import os.log

/// Posts notifications for activity that did **not** start on this device:
///
/// - **Channel messages** — posts from other people, channel webhooks, and
///   channel automations (including the model's reply once it finishes).
/// - **New chats from other sources** — chats created by automations, the web UI,
///   another device or the API, once their response has finished.
///
/// Two delivery paths share one de-duplication state:
/// 1. **Live** — socket listeners (`+Live`) that run while the app is open, or
///    briefly after it was backgrounded until iOS suspends it.
/// 2. **Background check** — (`+Checks`) run from `BackgroundTaskService`'s
///    app-refresh task. iOS decides when that runs, so it's a catch-up path.
@MainActor
final class ExternalActivityNotifier {

    static let shared = ExternalActivityNotifier()

    // MARK: - Settings

    /// Settings → Notifications → "Channel Messages".
    static let channelNotificationsKey = "channelNotificationsEnabled"
    /// Settings → Notifications → "New Chats from Other Sources".
    static let externalChatNotificationsKey = "externalChatNotificationsEnabled"

    static var channelNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: channelNotificationsKey) as? Bool ?? true
    }

    static var externalChatNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: externalChatNotificationsKey) as? Bool ?? true
    }

    // MARK: - Wiring

    /// Set by `AppDependencyContainer.init` (also runs on a background launch).
    weak var dependencies: AppDependencyContainer?

    let logger = Logger(subsystem: "com.openui", category: "ExternalActivity")
    var chatSubscription: SocketSubscription?
    var channelSubscription: SocketSubscription?
    var inFlightChatIds: Set<String> = []
    var isCheckingInBackground = false
    var lastCatchUp: Date = .distantPast

    /// Chats older than this are never announced.
    let maxChatAge: TimeInterval = 24 * 60 * 60
    /// A reply still "in progress" after this long is treated as stuck and skipped.
    let stalePendingAge: TimeInterval = 30 * 60
    /// How long de-duplication records are kept.
    private let retention: TimeInterval = 7 * 24 * 60 * 60

    private init() {}

    // MARK: - Persistent State

    /// Per-account de-duplication state, persisted so it survives relaunches.
    nonisolated struct State: Codable {
        /// When notifications were first set up for this account. Anything older is ignored.
        var baseline: Double
        /// Chats already evaluated (notified or deliberately skipped).
        var seenChatIds: [String: Double] = [:]
        /// Per-channel timestamp of the newest message already processed by the background check.
        var channelCursors: [String: Double] = [:]
        /// Channel messages already announced (live or background).
        var notifiedMessageIds: [String: Double] = [:]
        /// Channel messages older than this are treated as seen (last time the app was opened).
        var channelFloor: Double = 0
    }

    /// Stable key for the active server + account.
    var stateKey: String? {
        guard let deps = dependencies, let server = deps.serverConfigStore.activeServer else { return nil }
        return "\(server.id)|\(deps.serverConfigStore.activeAccount?.id ?? "default")"
    }

    /// The signed-in user's server ID, used to recognise the user's own messages.
    var currentUserId: String? {
        if let id = dependencies?.authViewModel.currentUser?.id, !id.isEmpty { return id }
        if let id = dependencies?.serverConfigStore.activeAccount?.userId,
           !id.isEmpty, !id.hasPrefix("legacy_") { return id }
        return nil
    }

    private func storageKey(_ key: String) -> String { "extNotif.state.\(key)" }

    func loadState(_ key: String) -> State {
        if let data = UserDefaults.standard.data(forKey: storageKey(key)),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        let fresh = State(baseline: Date().timeIntervalSince1970)
        saveState(fresh, key: key)
        return fresh
    }

    private func saveState(_ state: State, key: String) {
        var pruned = state
        let cutoff = Date().timeIntervalSince1970 - retention
        pruned.seenChatIds = pruned.seenChatIds.filter { $0.value >= cutoff }
        pruned.notifiedMessageIds = pruned.notifiedMessageIds.filter { $0.value >= cutoff }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: storageKey(key))
        }
    }

    /// Load → mutate → save in one synchronous step (safe across `await` interleaving).
    func mutateState(_ key: String, _ body: (inout State) -> Void) {
        var state = loadState(key)
        body(&state)
        saveState(state, key: key)
    }

    func markChatSeen(_ chatId: String, key: String) {
        mutateState(key) { $0.seenChatIds[chatId] = Date().timeIntervalSince1970 }
    }
}
