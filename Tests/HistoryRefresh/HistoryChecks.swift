@main struct HistoryChecks {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--benchmark") {
            benchmark(Int(CommandLine.arguments[2])!, mode: CommandLine.arguments[3])
            return
        }
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL", name) }
        }
        let source = ChatSourceReference(id: "invented-source", title: "Imaginary Observatory",
                                        url: "https://example.test/comet", snippet: "An invented comet.",
                                        type: "web", metadata: ["sample": "invented"])
        let file = ChatMessageFile(type: "file", url: "https://example.test/catalog.txt",
                                   name: "invented-catalog.txt", contentType: "text/plain")
        let error = ChatMessageError(content: "An invented error.")
        for streaming in [false, true] {
            for localStreaming in [false, true] {
                for role in [MessageRole.user, .assistant, .system] {
                    for text in ["", " ", "\n\t\u{2003}", "Invented comet.", "\u{200B}", "🌙 fictional"] {
                        let local = ChatMessage(id: "invented-guard", role: role, content: text, isStreaming: localStreaming)
                        let remote = ChatMessage(id: local.id, role: role, content: "Invented server answer.")
                        let vm = Subject()
                        vm.isStreaming = streaming
                        vm.conversation = Conversation(title: "Invented guard", messages: [local])
                        vm.adoptServerMessages(serverConversation: Conversation(title: "Invented guard", messages: [remote]))
                        let preserves = streaming && !localStreaming && role == .assistant
                            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        check(vm.conversation!.messages[0].content == (preserves ? text : remote.content), "streaming content guard")
                        check(!vm.conversation!.messages[0].isStreaming, "server completion state")
                    }
                }
            }
        }
        let live = Subject()
        live.conversation = Conversation(title: "Invented live stream", messages: [
            ChatMessage(id: "invented-live", role: .assistant, content: "Invented live delta.", isStreaming: true)])
        live.isStreaming = true
        live.streamingStore.isActive = true
        live.streamingStore.streamingMessageId = "invented-live"
        live.adoptServerMessages(serverConversation: Conversation(title: "Invented live stream", messages: [
            ChatMessage(id: "invented-live", role: .assistant, content: "Invented stale response.")]))
        check(live.conversation!.messages[0].content == "Invented live delta.", "live pipeline content retained")
        check(live.conversation!.messages[0].isStreaming, "live pipeline state retained")
        for count in [1, 2, 12, 100, 1000] {
            var history = makeHistory(count)
            if count >= 2 {
                let parent = "invented-comet-\(count-2)"
                history.addNode(HistoryNode(id: "invented-alternative", parentId: parent, role: .assistant,
                    content: "An invented alternative branch.", timestamp: Date(timeIntervalSince1970: -1),
                    files: [file], sources: [source], followUps: ["Invented alternate follow-up"], error: error))
                history.appendChildId("invented-alternative", to: parent)
            }
            let oldMessages = history.createMessagesList()
            let vm = Subject()
            vm.conversation = Conversation(title: "Invented background reply", history: history, messages: oldMessages)
            let previous = history.currentId!
            history.addNode(HistoryNode(id: "invented-extra", parentId: previous, role: .assistant,
                                       content: "An invented background reply.", timestamp: Date(timeIntervalSince1970: Double(count))))
            history.appendChildId("invented-extra", to: previous)
            let remote = Conversation(title: "Invented background reply", history: history, messages: oldMessages)
            vm.writes=0
            vm.adoptServerMessages(serverConversation: remote)
            check(vm.writes < 10,"background adoption batches observable history assignments")
            history.currentId = "invented-extra"
            check(vm.conversation!.messages == history.createMessagesList(), "background tree becomes visible")
            check(vm.conversation!.messages.count == count + 1, "background count")
            check(vm.conversation!.history.currentId == "invented-extra", "stale current ID follows deepest leaf")
            if count >= 2 {check(vm.conversation!.messages[count-1].versions.first?.id == "invented-alternative", "branch version survives snapshot reuse")}
        }
        for deferred in [false,true] {
            for allowsSync in [false,true] {
                let vm=Subject();vm.availableModels=[SyntheticModel(id:"invented-default")]
                var fetched=Conversation(title:"Invented metadata load",tasks:[ChatTask(id:"invented-task",content:"Invent a comet.",status:"pending")],files:[file])
                fetched.hasDeferredDetails=deferred
                vm.prepareLoadedConversation(fetched,allowSync:allowsSync)
                check(vm.conversation!.tasks == fetched.tasks && vm.tasks == fetched.tasks,"loaded tasks preserved")
                check(vm.chatFiles == [file],"loaded attachment context preserved")
                check(vm.selectedModelId == "invented-default","available model fallback")
                check(vm.backfills == (!deferred && allowsSync ? 1 : 0),"deferred and offline backfill guard")
            }
        }
        for count in [0,1,12,1000] {
            var local=makeHistory(count)
            local.addNode(HistoryNode(id:"invented-local-only",role:.assistant,content:"Preserved invented local branch."))
            local.nodes["invented-local-only"]!.contextSummary="Preserve this invented checkpoint."
            var remote=makeHistory(count)
            for index in 0..<count {
                remote.nodes["invented-comet-\(index)"]!.contextSummary=index%2 == 0 ? "Invented checkpoint \(index)." : nil
                local.nodes["invented-comet-\(index)"]!.contextSummary="Replace or clear an invented checkpoint."
            }
            remote.addNode(HistoryNode(id:"invented-remote-only",role:.assistant,content:"Do not insert this remote-only node."))
            let vm=Subject();let original=local.createMessagesList()
            vm.conversation=Conversation(id:"invented-context-chat",title:"Invented context refresh",history:local,messages:original)
            vm.conversation!.contextUsage=ChatContextUsage.parse(["tokens":17,"threshold":100])
            var refreshed=Conversation(id:"invented-context-chat",title:"Invented remote context",history:remote)
            refreshed.contextUsage=count%2 == 0 ? ChatContextUsage.parse(["tokens":29,"threshold":100]) : nil
            vm.writes=0
            vm.applyContextMetadata(refreshed)
            check(vm.conversation!.contextUsage == refreshed.contextUsage,"context usage replacement and clearing")
            check(vm.writes <= 2,"metadata refresh batches observable assignments")
            check(!vm.contextNeedsRefresh,"metadata recovery marker cleared")
            check(vm.conversation!.messages == original,"metadata refresh preserves visible messages")
            check(vm.conversation!.history.currentId == local.currentId,"metadata refresh preserves selected branch")
            check(vm.conversation!.history.nodes["invented-local-only"]!.contextSummary=="Preserve this invented checkpoint.","local-only checkpoint preserved")
            check(vm.conversation!.history.nodes["invented-remote-only"]==nil,"remote-only node is not inserted")
            for index in 0..<count {
                check(vm.conversation!.history.nodes["invented-comet-\(index)"]!.contextSummary == remote.nodes["invented-comet-\(index)"]!.contextSummary,"checkpoint replacement and clearing")
            }
            vm.writes=0;vm.contextNeedsRefresh=true
            vm.applyContextMetadata(Conversation(id:"invented-other-chat",title:"Invented unrelated chat",history:remote))
            check(vm.writes==0 && vm.contextNeedsRefresh,"unrelated chat rejected")
        }
        let absent=Subject();absent.conversationId="invented-absent-chat"
        absent.applyContextMetadata(Conversation(id:"invented-absent-chat",title:"Invented absent chat"))
        check(absent.conversation==nil && !absent.contextNeedsRefresh,"absent local conversation parity")
        let first = Subject()
        let server = Conversation(title: "Invented initial load", model: "invented-model", messages: [
            ChatMessage(id: "invented-first", role: .assistant, content: "An invented first reply.")])
        first.adoptServerMessages(serverConversation: server)
        check(first.conversation == server, "initial load")
        check(first.selectedModelId == "invented-model", "initial model")
        for count in [0, 1, 2, 12, 1000] {
            for variant in ["aligned", "short-flat", "missing-current", "cycle", "inactive", "flat-longer"] {
                var history = makeHistory(count)
                if variant == "missing-current" {history.currentId="invented-missing"}
                if variant == "cycle",count > 0 {history.nodes["invented-comet-0"]!.parentId=history.currentId}
                if variant == "inactive" {history.addNode(HistoryNode(id:"invented-inactive-load",role:.assistant,content:"Invented inactive branch."))}
                var messages = history.createMessagesList()
                if variant == "short-flat", !messages.isEmpty {messages.removeLast()}
                if variant == "flat-longer" {messages.append(ChatMessage(id:"invented-flat-only",role:.assistant,content:"Invented flat tail."))}
                let expected = history.createMessagesList()
                let fetched=Conversation(title:"Invented initial branch",model:"invented-model",history:history,messages:messages)
                let vm=Subject();vm.userDisabledBuiltinFeatures=["invented-feature"]
                vm.prepareLoadedConversation(fetched,allowSync:false)
                check(vm.conversation!.messages == (expected.count > messages.count ? expected : messages), "initial branch parity \(count) \(variant)")
                check(vm.conversation!.history.currentId == history.currentId,"initial current ID preserved")
                check(vm.backfills == 0 && vm.scans == 1 && vm.restores == 1,"offline load preserves control flow")
                check(vm.userDisabledBuiltinFeatures.isEmpty,"initial feature overrides reset")
                check(vm.selectedModelId == "invented-model","initial model restored")
            }
        }
        print("\(checks-failures)/\(checks) history checks passed")
        if failures > 0 { exit(1) }
    }

    static func makeHistory(_ count: Int) -> MessageHistory {
        var history = MessageHistory()
        for index in 0..<count {
            history.addNode(HistoryNode(id: "invented-comet-\(index)",
                parentId: index > 0 ? "invented-comet-\(index-1)" : nil,
                childrenIds: index + 1 < count ? ["invented-comet-\(index+1)"] : [],
                role: index % 2 == 0 ? .user : .assistant,
                content: "A freshly invented amber comet \(index).",
                timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        history.currentId = count > 0 ? "invented-comet-\(count-1)" : nil
        return history
    }

    static func cpu() -> Double {
        var usage = rusage()
        getrusage(0, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    @MainActor static func benchmark(_ count: Int, mode: String) {
        var history = makeHistory(count)
        let messages = history.createMessagesList()
        let local = Conversation(title: "Invented benchmark", history: history, messages: messages)
        let previous = history.currentId!
        history.addNode(HistoryNode(id: "invented-new", parentId: previous, role: .assistant,
                                   content: "Invented background reply.", timestamp: Date(timeIntervalSince1970: Double(count))))
        history.appendChildId("invented-new", to: previous)
        let remote = Conversation(title: local.title, history: history, messages: messages)
        let vm = Subject()
        vm.conversation = local
        vm.writes = 0
        let before = cpu(), start = ProcessInfo.processInfo.systemUptime
        if mode == "metadata" { vm.applyContextMetadata(local) }
        else if mode == "load" { vm.prepareLoadedConversation(local,allowSync:false) }
        else if mode == "adopt-aligned" { vm.adoptServerMessages(serverConversation: local) }
        else { vm.adoptServerMessages(serverConversation: remote) }
        let cpuMilliseconds = (cpu() - before) * 1000
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var memory = rusage()
        getrusage(0, &memory)
        if mode == "metadata" || mode == "load" || mode == "adopt-aligned" {
            precondition(vm.conversation!.messages == messages)
        } else {
            history.currentId = "invented-new"
            precondition(vm.conversation!.messages == history.createMessagesList())
        }
        print(String(data: try! JSONSerialization.data(withJSONObject: [
            "rows": count, "mode": mode, "writes": vm.writes,
            "cpu_ms": cpuMilliseconds, "wall_ms": wallMilliseconds,
            "peak_rss_bytes": memory.ru_maxrss
        ], options: .sortedKeys), encoding: .utf8)!)
    }
}
