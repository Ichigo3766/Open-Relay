import Foundation

@main struct Checks {
    @MainActor static func main() async {
        let expectedFixed = CommandLine.arguments.contains("--fixed")
        let oldUser = ChatMessage(id: "synthetic-old-user", role: .user, content: "Name a tree.")
        let oldAssistant = ChatMessage(id: "synthetic-old-assistant", role: .assistant, content: "Maple.")
        var history = MessageHistory()
        history.nodes[oldUser.id] = HistoryNode(id: oldUser.id, childrenIds: [oldAssistant.id], role: .user, content: oldUser.content)
        history.nodes[oldAssistant.id] = HistoryNode(id: oldAssistant.id, parentId: oldUser.id, role: .assistant, content: oldAssistant.content)
        history.currentId = oldAssistant.id
        let server = Conversation(id: "synthetic-chat", title: "Tree names", model: "synthetic-model", history: history, messages: [oldUser, oldAssistant])
        var passed = 0
        func check(_ result: Bool, _ label: String) {
            guard result else { print("FAIL: " + label); exit(1) }
            passed += 1
        }
        for connected in [true, false] {
            for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet] {
                let api = APIClient(server: server)
                api.historyError = code; api.completionError = code
                let vm = ChatViewModel(manager: Manager(apiClient: api), conversation: server)
                vm.socketService?.isConnected = connected
                vm.socketService?.isUserJoined = connected
                let text = "Synthetic retry message for \(code.rawValue)."
                vm.inputText = text
                var visibleBeforeFailure = false
                api.afterSyncAttempt = { visibleBeforeFailure = vm.conversation?.messages.contains(where: { $0.content == text }) ?? false }
                let started = await vm.sendMessage()
                await vm.streamingTask?.value
                check(visibleBeforeFailure, "optimistic bubble precedes server acceptance")
                check(!api.server.messages.contains(where: { $0.content == text }), "server never received message")
                if expectedFixed {
                    check(!started && api.completionAttempts == 0, "failed save blocks completion request")
                    check(vm.inputText == text && vm.errorMessage != nil, "draft and explicit error survive failure")
                    check(vm.conversation?.messages.map(\.id) == server.messages.map(\.id), "optimistic turn rolled back")
                } else {
                    check(started && api.completionAttempts == 1, "failed save is ignored and generation is attempted")
                    check(vm.inputText.isEmpty, "composer emptied despite failed delivery")
                    check(vm.conversation?.messages.contains(where: { $0.content == text }) == true, "unsaved user bubble remains after transport failure")
                    check(vm.conversation?.messages.last?.error != nil, "assistant gets transport error, user has no delivery receipt")
                }
                await vm.syncWithServer()
                check(vm.conversation?.messages.map(\.id) == server.messages.map(\.id), "server refresh removes failed local turn")
                await vm.reloadConversation()
                check(vm.conversation?.messages.map(\.id) == server.messages.map(\.id), "reopening cannot recover failed turn")
                if expectedFixed { check(vm.inputText == text, "draft survives refresh and reopening") }
                print("PASS \(connected ? "socket" : "polling fallback") \(code.rawValue): \(expectedFixed ? "draft restored; no completion request" : "visible locally; absent on server; removed after refresh")")
            }
        }
        // Control: if history reaches the server but generation fails, the prompt survives.
        let api = APIClient(server: server); api.completionError = .networkConnectionLost
        let vm = ChatViewModel(manager: Manager(apiClient: api), conversation: server)
        vm.inputText = "Synthetic saved message."
        check(await vm.sendMessage(), "successful save starts generation")
        await vm.streamingTask?.value
        await vm.syncWithServer()
        check(vm.conversation?.messages.contains(where: { $0.content == "Synthetic saved message." }) == true, "accepted user message survives refresh")
        check(api.server.messages.contains(where: { $0.content == "Synthetic saved message." }), "accepted history is durable on mock server")
        print("PASS saved-history control: message survives failed generation")
        // First-message chats can retain the turn in the in-memory tree on incremental reload.
        // A full server load (including reopening after losing the VM) removes that unsaved turn.
        let freshAPI = APIClient(server: Conversation(id: "synthetic-empty", title: "Empty"))
        freshAPI.historyError = .networkConnectionLost; freshAPI.completionError = .networkConnectionLost
        let freshVM = ChatViewModel(manager: Manager(apiClient: freshAPI), conversation: nil)
        freshVM.inputText = "Synthetic first message."
        let freshStarted = await freshVM.sendMessage()
        await freshVM.streamingTask?.value
        check(freshStarted != expectedFixed, "new-chat send result reflects save failure")
        freshVM.conversationId = freshAPI.server.id
        await freshVM.loadConversation()
        check(freshVM.conversation?.messages.isEmpty == true, "empty server chat has no delivered turn")
        check(freshVM.inputText == (expectedFixed ? "Synthetic first message." : ""), "new-chat draft retention")
        print("PASS newly created chat: \(expectedFixed ? "draft retained" : "local turn removed on full load")")
        // Reconciliation must continue to adopt legitimate server-side deletions and additions.
        let reconcileAPI = APIClient(server: server)
        let reconcileVM = ChatViewModel(manager: Manager(apiClient: reconcileAPI), conversation: server)
        let replacement = ChatMessage(id: "synthetic-replacement", role: .assistant, content: "Birch.")
        var replacementHistory = history
        replacementHistory.nodes.removeValue(forKey: oldAssistant.id)
        replacementHistory.nodes[oldUser.id]?.childrenIds = [replacement.id]
        replacementHistory.nodes[replacement.id] = HistoryNode(id: replacement.id, parentId: oldUser.id, role: .assistant, content: replacement.content)
        replacementHistory.currentId = replacement.id
        reconcileAPI.server.history = replacementHistory
        reconcileAPI.server.messages = [oldUser, replacement]
        await reconcileVM.reloadConversation()
        check(reconcileVM.conversation?.messages.map(\.id) == [oldUser.id, replacement.id], "server deletion and replacement still adopted")
        print("PASS authoritative reconciliation control")
        let creationAPI = APIClient(server: server)
        creationAPI.createError = .notConnectedToInternet
        let creationVM = ChatViewModel(manager: Manager(apiClient: creationAPI), conversation: nil)
        creationVM.inputText = "Synthetic chat creation draft."
        check(!(await creationVM.sendMessage()), "failed chat creation blocks sending")
        check(creationVM.inputText == "Synthetic chat creation draft." && creationVM.conversation == nil && creationAPI.completionAttempts == 0, "chat creation failure preserves original draft")
        print("PASS chat-creation failure control")
        let temporaryAPI = APIClient(server: server)
        temporaryAPI.historyError = .networkConnectionLost; temporaryAPI.completionError = .networkConnectionLost
        let temporaryVM = ChatViewModel(manager: Manager(apiClient: temporaryAPI), conversation: server)
        temporaryVM.isTemporaryChat = true; temporaryVM.inputText = "Synthetic temporary turn."
        check(await temporaryVM.sendMessage(), "temporary chat does not require history persistence")
        await temporaryVM.streamingTask?.value
        check(temporaryAPI.completionAttempts == 1 && temporaryVM.inputText.isEmpty, "temporary generation path is unchanged")
        check(temporaryVM.conversation?.messages.contains(where: { $0.content == "Synthetic temporary turn." }) == true, "temporary turn remains ephemeral in local conversation")
        print("PASS temporary-chat control")
        if expectedFixed {
            let retryAPI = APIClient(server: server)
            retryAPI.historyError = .timedOut
            let retryVM = ChatViewModel(manager: Manager(apiClient: retryAPI), conversation: server)
            retryVM.inputText = "Synthetic failed message."
            retryVM.attachments = [ChatAttachment(type: .file, name: "synthetic.txt", uploadedFileId: "synthetic-file")]
            retryVM.selectedKnowledgeItems = [Reference()]
            retryVM.selectedReferenceChats = [Reference()]
            retryVM.selectedNotes = [Note(id: "synthetic-note", title: "Note", content: "An invented note.")]
            retryVM.selectedSkillIds = ["synthetic-skill"]
            retryAPI.afterSyncAttempt = { retryVM.inputText = "Synthetic newer draft." }
            check(!(await retryVM.sendMessage()), "failure returns explicit failed-send result")
            check(retryVM.inputText == "Synthetic failed message.\n\nSynthetic newer draft.", "newer typing is preserved alongside failed draft")
            check(retryVM.attachments.count == 1 && retryVM.attachments.first?.uploadedFileId == "synthetic-file", "uploaded attachment preserved for manual retry")
            check(retryVM.selectedKnowledgeItems.count == 1 && retryVM.selectedReferenceChats.count == 1 && retryVM.selectedNotes.count == 1 && retryVM.selectedSkillIds == ["synthetic-skill"], "per-message selections restored")
            retryAPI.historyError = nil; retryAPI.afterSyncAttempt = nil
            check(await retryVM.sendMessage(), "manual retry starts after connection recovery")
            await retryVM.streamingTask?.value
            check(retryAPI.completionAttempts == 1 && retryVM.inputText.isEmpty, "manual retry produces one completion request and consumes draft")
            check(retryAPI.server.messages.filter { $0.role == .user && $0.content.hasPrefix("Synthetic failed message.") }.count == 1, "manual retry persists one user turn")
            print("PASS candidate: newer typing, attachment, references and manual retry")
            let queuedAPI = APIClient(server: server); queuedAPI.historyError = .networkConnectionLost
            let queuedVM = ChatViewModel(manager: Manager(apiClient: queuedAPI), conversation: server)
            queuedVM.enableMessageQueue = true; queuedVM.inputText = "Synthetic failed queued draft."
            var wasQueued = false
            queuedAPI.afterSyncAttempt = {
                wasQueued = !(await queuedVM.sendMessage(directText: "Synthetic queued follow-up."))
                queuedVM.inputText = "Synthetic newer text."
            }
            check(!(await queuedVM.sendMessage()) && wasQueued, "new send queues while original save is pending")
            check(queuedVM.inputText == "Synthetic failed queued draft.\n\nSynthetic queued follow-up.\n\nSynthetic newer text.", "failed draft, queued text and newer typing restored together")
            check(queuedVM.messageQueue.isEmpty && !queuedVM.isStreaming && !queuedVM.streamingStore.isActive, "failed save clears stream and consumes queue into draft")
            try? await Task.sleep(nanoseconds: 900_000_000)
            check(queuedAPI.completionAttempts == 0 && queuedAPI.syncAttempts == 1, "cleanup does not automatically resend queued text")
            print("PASS candidate: queued text retained without automatic retry")
            UserDefaults.standard.values["audioFileTranscriptionMode"] = "device"
            let audioAPI = APIClient(server: server); audioAPI.historyError = .timedOut
            let audioVM = ChatViewModel(manager: Manager(apiClient: audioAPI), conversation: server)
            let audio = ChatAttachment(type: .audio, name: "synthetic.m4a", data: Data([0, 1, 2]), transcribedText: "An invented transcript.")
            audioVM.attachments = [audio]
            check(!(await audioVM.sendMessage()), "attachment-only send fails explicitly")
            check(audioVM.attachments.first?.type == .audio && audioVM.attachments.first?.data == audio.data && audioVM.attachments.first?.transcribedText == audio.transcribedText, "original audio attachment restored rather than converted transcript")
            check(audioVM.inputText.isEmpty, "attachment-only failure has no fabricated text")
            UserDefaults.standard.values.removeValue(forKey: "audioFileTranscriptionMode")
            print("PASS candidate: original attachment retained after conversion")
            for change in ["scope", "chat", "stream"] {
                let changedAPI = APIClient(server: server); changedAPI.historyError = .timedOut
                let changedVM = ChatViewModel(manager: Manager(apiClient: changedAPI), conversation: server)
                changedVM.inputText = "Synthetic old draft."
                changedAPI.afterSyncAttempt = {
                    if change == "scope" { changedAPI.network.conversationCacheScope = "synthetic-other-session" }
                    else if change == "chat" { changedVM.conversation = Conversation(id: "synthetic-other-chat", title: "Other") }
                    else { changedVM.streamingSessionId += 1 }
                    changedVM.inputText = "Synthetic other-context draft."
                }
                check(!(await changedVM.sendMessage()), "changed context cancels failed send")
                check(changedVM.inputText == "Synthetic other-context draft.", "old draft is not restored into changed context")
                if change == "chat" { check(changedVM.conversation?.id == "synthetic-other-chat", "unrelated conversation is not rolled back") }
            }
            print("PASS candidate: changed conversation, session and newer stream are preserved")
        }
        print("\(passed) assertions passed (\(expectedFixed ? "candidate" : "upstream")).")
    }
}
