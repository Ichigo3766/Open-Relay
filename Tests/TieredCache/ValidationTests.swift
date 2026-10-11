import Foundation

@main struct ValidationTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func expect(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: " + name) }
    }
    @MainActor static func settle() async {
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }
    @MainActor static func cached() async -> (ConversationManager, ValidationSubject) {
        let manager = ConversationManager()
        let owner = ValidationSubject(manager: manager)
        await owner.loadConversation()
        await settle()
        expect(manager.pending != nil, "stale cached validation starts")
        expect(owner.conversation?.id == "invented-cached" && !owner.isLoadingConversation,
               "cached history appears before validation completes")
        return (manager, owner)
    }
    @MainActor static func main() async {
        let lifetimeManager = ConversationManager()
        var owner: ValidationSubject? = ValidationSubject(manager: lifetimeManager)
        weak var hidden = owner
        await owner!.loadConversation()
        await settle()
        expect(lifetimeManager.pending != nil, "lifetime request is pending")
        owner = nil
        await settle()
        expect(hidden == nil, "completed hidden history is released while validation waits")
        print("pending_validation_retained_model_count=\(hidden == nil ? 0 : 1)")
        lifetimeManager.finish(.success(Conversation(id: "invented-fetched")))
        await settle()
        expect(hidden == nil, "validation finishes safely after owner release")

        let (visibleManager, visible) = await cached()
        visibleManager.finish(.success(Conversation(id: "invented-fetched")))
        await settle()
        expect(visible.conversation?.id == "invented-fetched" && visible.lastSyncTime > .distantPast,
               "visible cached owner receives validation")

        let recentManager = ConversationManager()
        recentManager.apiClient.snapshot!.isRecent = true
        let recent = ValidationSubject(manager: recentManager)
        await recent.loadConversation()
        expect(recentManager.fetches == 0 && recent.lastSyncTime == recentManager.apiClient.snapshot!.validatedAt,
               "recent cache avoids validation")

        for mutation in 0..<3 {
            let (manager, subject) = await cached()
            if mutation == 0 { manager.apiClient.network.conversationCacheScope = "other-invented-account" }
            if mutation == 1 { subject.cacheValidation = UUID() }
            if mutation == 2 { subject.isStreaming = true }
            manager.finish(.success(Conversation(id: "invented-fetched")))
            await settle()
            expect(subject.conversation?.id == "invented-cached", "account/revision/stream guard \(mutation)")
        }
        for code in [401, 403, 404, 410] {
            let (manager, subject) = await cached()
            manager.finish(.failure(APIError.httpError(code, nil, nil)))
            await settle()
            expect(subject.conversation == nil && subject.tasks.isEmpty && subject.chatFiles.isEmpty && subject.errorMessage != nil,
                   "denied/deleted cache is removed: \(code)")
        }
        for error in [APIError.offline, APIError.other] {
            let (manager, subject) = await cached()
            manager.finish(.failure(error))
            await settle()
            expect(subject.conversation?.id == "invented-cached", "cached history survives validation error")
            expect((subject.errorMessage != nil) == !error.isConnectivityError, "cached error reporting")
        }
        for policy in [0, 1, 2] {
            let manager = ConversationManager()
            if policy == 0 { manager.apiClient.snapshot = nil }
            else { manager.apiClient.snapshot!.allowsStale = policy == 1 ? nil : false }
            let subject = ValidationSubject(manager: manager)
            let loading = Task { await subject.loadConversation() }
            await settle()
            expect(subject.isLoadingConversation && subject.conversation == nil, "uncached load waits for request")
            if policy == 0 { manager.finish(.success(Conversation(id: "invented-fetched"))) }
            else { manager.finish(.failure(APIError.offline)) }
            await loading.value
            expect(!subject.isLoadingConversation, "uncached load completes")
            if policy == 0 { expect(subject.conversation?.id == "invented-fetched", "uncached success") }
            if policy == 1 { expect(subject.conversation?.id == "invented-cached" && !subject.syncAllowed, "legacy offline fallback") }
            if policy == 2 { expect(subject.conversation == nil && subject.errorMessage != nil, "HTTP policy forbids stale fallback") }
        }
        let cancelManager = ConversationManager()
        cancelManager.apiClient.snapshot = nil
        let canceledOwner = ValidationSubject(manager: cancelManager)
        let canceledLoad = Task { await canceledOwner.loadConversation() }
        await settle()
        canceledLoad.cancel()
        await settle()
        expect(cancelManager.cancellations == 1, "uncached caller cancellation reaches the request")
        cancelManager.finish(.failure(APIError.offline))
        await canceledLoad.value
        expect(!canceledOwner.isLoadingConversation, "canceled cold load completes")
        print("\(checks - failures)/\(checks) synthetic loading checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
