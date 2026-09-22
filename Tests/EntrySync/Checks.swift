import Foundation

@MainActor struct Task {
    static var pending: [@MainActor () async -> Void] = []
    @discardableResult init(@_implicitSelfCapture operation: @escaping @MainActor () async -> Void) {
        Self.pending.append(operation)
    }
    static func drain() async {
        while !pending.isEmpty { await pending.removeFirst()() }
    }
}

struct Conversation { let id: String }
struct Logger { func debug(_ text: String) {} }
enum SyntheticError: Error { case unavailable }

@MainActor final class Manager {
    var fetches = 0
    var fail = false
    func fetchConversation(id: String) async throws -> Conversation {
        fetches += 1
        if fail { throw SyntheticError.unavailable }
        return Conversation(id: id)
    }
}

@MainActor final class Chat {
    var hasLoaded = true
    var isStreaming = false
    var isExternallyStreaming = false
    var conversationId: String? = "synthetic-chat"
    var conversation: Conversation?
    var manager: Manager? = Manager()
    var lastSyncTime = Date.distantPast
    var lastEntryTime = Date.distantPast
    let syncDebounceInterval: TimeInterval = 3.0
    let logger = Logger()
    // ENTRY_METHOD
    // FETCH_GATE
}

@main enum Checks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        let recent = Chat()
        await recent.syncWithServer()
        let completedAt = recent.lastSyncTime
        recent.syncOnEntry()
        await Task.drain()
        check(recent.manager!.fetches == 1, "entry after a successful sync does not fetch again")
        check(recent.lastSyncTime == completedAt, "entry preserves the last successful sync timestamp")
        recent.lastEntryTime = Date().addingTimeInterval(-2)
        recent.syncOnEntry()
        await Task.drain()
        check(recent.manager!.fetches == 1, "entry past the appearance guard still respects the shared debounce")

        recent.lastSyncTime = Date().addingTimeInterval(-4)
        recent.lastEntryTime = Date().addingTimeInterval(-2)
        let beforeStaleEntry = recent.manager!.fetches
        recent.syncOnEntry()
        recent.syncOnEntry()
        await Task.drain()
        check(recent.manager!.fetches == beforeStaleEntry + 1, "stale re-entry fetches once despite duplicate appearances")

        let first = Chat()
        first.hasLoaded = false
        first.syncOnEntry()
        await Task.drain()
        check(first.manager!.fetches == 0, "initial load remains responsible for the first fetch")
        first.hasLoaded = true
        first.isStreaming = true
        first.syncOnEntry()
        await Task.drain()
        check(first.manager!.fetches == 0, "navigation does not interrupt streaming")
        first.isStreaming = false
        first.syncOnEntry()
        await Task.drain()
        check(first.manager!.fetches == 1, "loaded chat without a recent sync fetches")

        let retry = Chat()
        retry.manager!.fail = true
        retry.syncOnEntry()
        await Task.drain()
        check(retry.lastSyncTime == .distantPast, "failed fetch does not count as a successful sync")
        retry.manager!.fail = false
        retry.lastEntryTime = Date().addingTimeInterval(-2)
        retry.syncOnEntry()
        await Task.drain()
        check(retry.manager!.fetches == 2 && retry.lastSyncTime != .distantPast, "next eligible entry retries a failed fetch")
        if failures > 0 { exit(1) }
        print("PASS: recent/stale sync, duplicate appearances, first load, streaming, failed-fetch retry")
    }
}
