import Foundation

@MainActor struct Task {
    static var pending: [@MainActor () async -> Void] = []
    @discardableResult init(operation: @escaping @MainActor () async -> Void) {
        Self.pending.append(operation)
    }
    static func drain() async {
        while !pending.isEmpty { await pending.removeFirst()() }
    }
}

enum UIApplication {
    static let willEnterForegroundNotification = Notification.Name("synthetic-foreground")
    static let didEnterBackgroundNotification = Notification.Name("synthetic-background")
}

// In-memory main-queue notifications keep lifecycle delivery deterministic.
@MainActor final class NotificationCenter {
    static let `default` = NotificationCenter()
    var observers: [(NSObject, Notification.Name, @MainActor (Notification) -> Void)] = []
    func addObserver(forName name: Notification.Name, object: Any?, queue: OperationQueue?,
                     using block: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
        let token = NSObject()
        observers.append((token, name, block))
        return token
    }
    func removeObserver(_ token: NSObjectProtocol) {
        observers.removeAll { $0.0.isEqual(token) }
    }
    func post(_ name: Notification.Name) {
        for (_, observed, block) in observers where observed == name {
            block(Notification(name: name))
        }
    }
}

struct Logger {
    func debug(_ text: String) {}
    func info(_ text: String) {}
}

@MainActor final class Chat {
    // VISIBILITY
    var isStreaming = false
    var backgroundEnteredAt: Date?
    var foregroundObserver: NSObjectProtocol?
    var backgroundObserver: NSObjectProtocol?
    var wasBackgroundedDuringThisStream = false
    var pendingResumeTranscriptions: [UUID: (audioData: Data, fileName: String)] = [:]
    let logger = Logger()
    var syncs = 0
    var paramsFetches = 0
    var recoveries = 0
    var polls = 0
    var resumed: [UUID] = []
    func syncWithServer() async { syncs += 1 }
    func fetchUserDefaultParamsFromServer() async { paramsFetches += 1 }
    func recoverFromBackgroundStreaming() async { recoveries += 1 }
    func startBackgroundCompletionPolling() { polls += 1 }
    func transcribeAudioAttachment(attachmentId: UUID, audioData: Data, fileName: String) {
        resumed.append(attachmentId)
    }
    // LISTENERS
}

@MainActor struct Detail {
    let viewModel: Chat
    // VIEW_ID
    func appear() {
        // APPEAR
    }
    func disappear() {
        // DISAPPEAR
    }
}

@main enum Checks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        let chats = (0..<5).map { _ in Chat() }
        let detail = Detail(viewModel: chats[0])
        detail.appear()
        check(!chats[0].visibleViewIDs.isEmpty, "appearance marks the chat visible")
        chats[1].isStreaming = true // Hidden streams still need recovery.
        let attachment = UUID()
        chats[2].pendingResumeTranscriptions[attachment] = (Data([0, 1]), "synthetic.wav")
        for chat in chats {
            chat.startForegroundSyncListener()
            chat.startForegroundSyncListener() // Existing observers must be replaced.
        }
        let center = NotificationCenter.default
        check(center.observers.count == 10, "one observer pair per cached chat")
        center.post(UIApplication.didEnterBackgroundNotification)
        await Task.drain()
        check(chats.allSatisfy { $0.backgroundEnteredAt != nil }, "background time recorded")
        check(chats[1].polls == 1 && chats[1].wasBackgroundedDuringThisStream, "hidden stream completion monitoring preserved")
        for chat in chats { chat.backgroundEnteredAt = Date().addingTimeInterval(-30) }
        center.post(UIApplication.willEnterForegroundNotification)
        await Task.drain()
        check(chats[0].syncs == 1 && chats[0].paramsFetches == 1, "visible idle chat refreshes")
        check(chats.dropFirst().allSatisfy { $0.syncs == 0 && $0.paramsFetches == 0 }, "hidden idle chats do not fetch")
        check(chats[1].recoveries == 1, "hidden streaming chat recovers")
        check(chats[2].resumed == [attachment] && chats[2].pendingResumeTranscriptions.isEmpty, "hidden paused transcription resumes once")
        check(chats.allSatisfy { $0.backgroundEnteredAt == nil }, "foreground clears background timestamp")

        for chat in chats { chat.backgroundEnteredAt = Date().addingTimeInterval(-1) }
        center.post(UIApplication.willEnterForegroundNotification)
        await Task.drain()
        check(chats[0].syncs == 1, "brief background skips idle sync")
        check(chats[1].recoveries == 2, "brief background still recovers streaming")
        check(chats[2].resumed.count == 1, "transcription is not resumed twice")

        detail.disappear()
        check(chats[0].visibleViewIDs.isEmpty, "disappearance clears visibility")
        center.post(UIApplication.willEnterForegroundNotification) // Unknown duration.
        await Task.drain()
        check(chats[0].syncs == 1, "disappeared chat remains cached without idle refresh")
        detail.appear()
        center.post(UIApplication.willEnterForegroundNotification)
        await Task.drain()
        check(chats[0].syncs == 2, "reopened chat refreshes with unknown background duration")
        let otherWindow = Detail(viewModel: chats[0])
        otherWindow.appear()
        detail.disappear()
        check(!chats[0].visibleViewIDs.isEmpty, "closing one view preserves visibility in another window")
        center.post(UIApplication.willEnterForegroundNotification)
        await Task.drain()
        check(chats[0].syncs == 3, "chat visible in another window still refreshes")
        otherWindow.disappear()
        otherWindow.disappear()
        check(chats[0].visibleViewIDs.isEmpty, "repeated disappearance leaves the chat hidden")
        detail.appear()
        detail.appear()
        detail.disappear()
        check(chats[0].visibleViewIDs.isEmpty, "repeated appearance does not leave stale visibility")
        if failures > 0 { exit(1) }
        print("PASS: five cached chats, multiple views, repeated lifecycle callbacks, short/unknown background, streaming and transcription recovery")
    }
}
