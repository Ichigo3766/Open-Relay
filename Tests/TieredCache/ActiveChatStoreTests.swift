import Foundation

@main struct Checks {
    @MainActor static var count = 0
    @MainActor static func expect(_ value: Bool, _ message: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED: " + message + "\n").utf8)) }
        precondition(value, message)
        count += 1
    }
    @MainActor static func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }
    @MainActor static func main() async {
        let store = ActiveChatStore()
        var visible: ChatViewModel? = store.viewModel(for: "visible")
        expect(store.viewModel(for: "visible") === visible, "a visible chat reuses the view-owned model")
        weak var previous = visible
        store.disappeared(visible!)
        visible = nil
        await settle()
        expect(previous == nil, "completed hidden models are released")

        var drafting: ChatViewModel? = store.viewModel(for: "drafting")
        drafting!.inputText = "Invent a teal observatory."
        let attachment = ChatAttachment(name: "invented.txt")
        drafting!.attachments = [attachment]
        drafting!.conversation = FixtureConversation(id: "drafting", payload: Data(repeating: 7, count: 1024 * 1024))
        weak var oldDraft = drafting
        store.disappeared(drafting!)
        drafting = nil
        await settle()
        expect(oldDraft == nil, "draft snapshots do not retain the full conversation")
        var restored: ChatViewModel? = store.viewModel(for: "drafting")
        expect(restored!.inputText == "Invent a teal observatory." && restored!.attachments.first?.id == attachment.id,
               "unsent text and attachments survive reconstruction")
        expect(restored!.conversation == nil, "completed history is rebuilt from the disk cache")
        restored!.inputText = ""
        restored!.attachments = []
        store.disappeared(restored!)
        restored = nil
        expect(store.viewModel(for: "drafting").inputText.isEmpty, "cleared drafts stay cleared")

        let dependencies = AppDependencyContainer()
        store.prewarm(conversationId: "destination", using: dependencies)
        weak var warmed = store.viewModel(for: "destination")
        expect(warmed?.isConfigured == true, "prewarming survives the navigation handoff")
        var destination: ChatViewModel? = store.viewModel(for: "destination")
        store.appeared(destination!)
        store.disappeared(destination!)
        destination = nil
        await settle()
        expect(warmed == nil, "navigation handoff does not become an idle cache")

        let flags: [WritableKeyPath<ChatViewModel, Bool>] = [
            \.isStreaming, \.hasActiveTranscriptions, \.hasUploadingAttachments,
            \.isCreatingConversation, \.isCreatingNoteChat, \.isSavingContext,
            \.isCompactingContext, \.isSavingChatVariables, \.isSavingTemporaryChat,
            \.isResolvingToolCall, \.isResolvingAskUser, \.isCheckingToolConnections, \.isVoiceMode
        ]
        for (index, flag) in flags.enumerated() {
            let id = "working-\(index)"
            var model: ChatViewModel? = store.viewModel(for: id)
            model![keyPath: flag] = true
            weak var work = model
            store.disappeared(model!)
            model = nil
            await settle()
            expect(work != nil && store.viewModel(for: id) === work, "ongoing work stays alive after navigation")
            work![keyPath: flag] = false
            await settle()
            expect(work == nil, "completion releases a hidden model automatically")
        }

        var queued: ChatViewModel? = store.viewModel(for: "queued")
        queued!.messageQueue = [QueuedMessage(text: "Invent a moon.")]
        weak var queue = queued
        store.disappeared(queued!)
        queued = nil
        await settle()
        expect(queue != nil, "queued sends stay alive")
        queue!.pendingTextAfterUpload = "Invent a star."
        queue!.messageQueue = []
        await settle()
        expect(queue != nil, "switching between kinds of work does not release the model")
        queue!.pendingTextAfterUpload = nil
        await settle()
        expect(queue == nil, "finishing the final kind of work releases the model")

        var delayed: ChatViewModel? = store.viewModel(for: "delayed-send")
        delayed!.messageQueue = [QueuedMessage(text: "Invent a silver telescope.")]
        delayed!.drainMessageQueue(after: 80_000_000)
        weak var draining = delayed
        store.disappeared(delayed!)
        delayed = nil
        await settle()
        expect(draining != nil, "clearing the queue does not release a scheduled send during its delay")
        try? await Task.sleep(for: .milliseconds(120))
        await settle()
        expect(ChatViewModel.deliveries == ["Invent a silver telescope."] && draining == nil,
               "delayed queue sends finish and release hidden history")

        var paused: ChatViewModel? = store.viewModel(for: "paused-transcription")
        paused!.attachments = [ChatAttachment(name: "invented.wav", isTranscribing: true)]
        weak var transcription = paused
        store.disappeared(paused!)
        paused = nil
        await settle()
        expect(transcription != nil, "paused transcription keeps its resumable state")
        transcription!.attachments[0].isTranscribing = false
        await settle()
        expect(transcription == nil, "completed transcription snapshots attachments and releases history")

        var prompt: ChatViewModel? = store.viewModel(for: "prompt")
        prompt!.toolEventPrompts.requests = [1]
        weak var pendingPrompt = prompt
        store.disappeared(prompt!)
        prompt = nil
        await settle()
        expect(pendingPrompt != nil, "unanswered tool prompts are retained")
        pendingPrompt!.toolEventPrompts.requests = []
        await settle()
        expect(pendingPrompt == nil, "answering the final prompt releases a hidden model")

        var temporary: ChatViewModel? = store.viewModel(for: nil)
        temporary!.isTemporaryChat = true
        temporary!.conversation = FixtureConversation(id: "local:invented")
        weak var unsaved = temporary
        store.disappeared(temporary!)
        temporary = nil
        await settle()
        expect(unsaved != nil, "unsaved temporary history is not discarded")
        store.remove(nil)
        await settle()
        expect(unsaved == nil, "explicit new-chat discard releases temporary history")

        var uploading: ChatViewModel? = store.viewModel(for: nil)
        uploading!.hasUploadingAttachments = true
        weak var oldUpload = uploading
        store.remove(nil)
        uploading = nil
        let fresh = store.viewModel(for: nil)
        await settle()
        expect(oldUpload != nil && oldUpload !== fresh, "new chat does not cancel an older upload or reuse its draft")
        oldUpload!.conversationId = "created-after-navigation"
        store.retain(oldUpload!, for: "created-after-navigation")
        expect(store.viewModel(for: "created-after-navigation") === oldUpload && store.viewModel(for: nil) === fresh,
               "late creation keeps the originating model identity")
        oldUpload!.hasUploadingAttachments = false
        await settle()
        expect(oldUpload == nil, "late-created work is released after completion")

        var superseded: ChatViewModel? = store.viewModel(for: "replaced")
        superseded!.isStreaming = true
        weak var replaced = superseded
        superseded = nil
        await settle()
        let replacement = ChatViewModel(conversationId: "replaced")
        store.retain(replacement, for: "replaced")
        expect(replaced != nil, "replacing a lookup does not interrupt earlier ongoing work")
        replaced!.isStreaming = false
        await settle()
        expect(replaced == nil, "unregistered completed work releases its owner")

        var background: ChatViewModel? = store.viewModel(for: "old-account")
        background!.isStreaming = true
        weak var oldAccount = background
        background!.inputText = "Invent an amber telescope."
        store.disappeared(background!)
        background = nil
        store.clear() // A scheduled observation must not restore the old account's model or draft.
        await settle()
        expect(oldAccount == nil, "account clear wins against scheduled retention callbacks")
        expect(store.viewModel(for: "old-account").inputText.isEmpty, "account clear removes lightweight drafts")
        var canceled: ChatViewModel? = store.viewModel(for: "canceled-send")
        canceled!.messageQueue = [QueuedMessage(text: "This invented send must be canceled.")]
        canceled!.drainMessageQueue(after: 80_000_000)
        weak var canceledSend = canceled
        canceled = nil
        store.clear()
        try? await Task.sleep(for: .milliseconds(120))
        await settle()
        expect(canceledSend == nil && ChatViewModel.deliveries.count == 1, "account clear prevents a delayed old-session send")
        store.clear()
        print("Passed \(count) synthetic chat ownership checks.")
    }
}
