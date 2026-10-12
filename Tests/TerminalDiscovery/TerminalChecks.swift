import Foundation
import Darwin

@MainActor private final class WeakOwner {
    weak var value: Subject?
    init(_ value: Subject) { self.value = value }
}

@main struct TerminalChecks {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func expect(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: " + name) }
    }
    @MainActor static func settle() async {
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    @MainActor static func benchmark() async {
        let manager = ConversationManager()
        let socket = SyntheticSocket()
        let socketBenchmark = CommandLine.arguments.contains("--benchmark-socket")
        let paramsBenchmark = CommandLine.arguments.contains("--benchmark-params")
        var current: Subject?
        var owners: [WeakOwner] = []
        let before = residentBytes()
        for n in 1...6 {
            current = Subject(manager: manager, size: 16 * 1024 * 1024, seed: UInt8(n), socket: socketBenchmark ? socket : nil)
            owners.append(WeakOwner(current!))
            if paramsBenchmark { current!.startupParams() } else if socketBenchmark { current!.startupSocket() } else { current!.startup() }
            await settle()
        }
        await settle()
        let retained = owners.compactMap(\.value).count
        let result: [String: Any] = ["retained_models": retained,
            "retained_fixture_bytes": retained * 16 * 1024 * 1024,
            "resident_before_bytes": before, "resident_pending_bytes": residentBytes(),
            "pending_requests": paramsBenchmark ? manager.apiClient.pending.count : socketBenchmark ? socket.pending.count : manager.pending.count]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
        manager.finish(.success([TerminalServer(id: "invented-planetarium")]))
        manager.apiClient.finish(.success(Params(defaultUploadContext:"invented-context",hasAnyOverride:false)))
        socket.finish(false)
        await settle()
        current = nil
        await settle()
    }
    @MainActor static func main() async {
        if (CommandLine.arguments.contains("--benchmark") || CommandLine.arguments.contains("--benchmark-socket") || CommandLine.arguments.contains("--benchmark-params")) { await benchmark(); return }
        let lifetime = ConversationManager()
        var hidden: [WeakOwner] = []
        for n in 1...6 {
            var owner: Subject? = Subject(manager: lifetime, size: 16 * 1024 * 1024, seed: UInt8(n))
            hidden.append(WeakOwner(owner!))
            owner!.startup()
            await settle()
            owner = nil
        }
        await settle()
        expect(lifetime.pending.count == 6, "six terminal requests are suspended")
        let retained = hidden.compactMap(\.value).count
        print("pending_terminal_retained_model_count=\(retained)")
        expect(retained == 0, "hidden histories are released before terminal discovery returns")
        lifetime.finish(.success([TerminalServer(id: "invented-planetarium")]))
        await settle()
        expect(hidden.compactMap(\.value).isEmpty, "request completion is safe after owner release")

        let first = TerminalServer(id: "invented-first")
        let second = TerminalServer(id: "invented-second")
        for variant in 0..<4 {
            let manager = ConversationManager()
            let owner = Subject(manager: manager)
            if variant > 0 { owner.selectedTerminalServer = first; owner.terminalEnabled = true }
            owner.startup()
            await settle()
            let servers = variant == 2 ? [] : variant == 3 ? [second] : [first, second]
            manager.finish(.success(servers))
            await settle()
            expect(owner.availableTerminalServers == servers, "visible terminal list is adopted \(variant)")
            expect(owner.activeChatStore?.cachedTerminalServers == servers, "shared list is updated \(variant)")
            expect(owner.selectedTerminalServer == servers.first, "terminal selection is preserved or replaced \(variant)")
            expect(owner.terminalEnabled == (variant > 0 && variant != 2), "empty list disables a vanished terminal \(variant)")
            expect(owner.pendingApplies == 1, "pending model default is applied \(variant)")
        }
        let failedManager = ConversationManager()
        let failed = Subject(manager: failedManager)
        failed.availableTerminalServers = [first]
        failed.startup()
        await settle()
        failedManager.finish(.failure(NSError(domain: "org.example.synthetic", code: 1)))
        await settle()
        expect(failed.availableTerminalServers == [first], "failure preserves the existing list")
        expect(failed.logger.errors == 1 && failed.pendingApplies == 1, "failure logging and pending defaults are preserved")

        let noManager = Subject(manager: nil)
        noManager.startup()
        await settle()
        expect(noManager.pendingApplies == 0, "missing manager is a no-op")
        let connection = SyntheticSocket()
        var connecting: [WeakOwner] = []
        for n in 1...6 {
            var owner: Subject? = Subject(manager: nil, size: 16 * 1024 * 1024, seed: UInt8(n), socket: connection)
            connecting.append(WeakOwner(owner!)); owner!.startupSocket(); await settle(); owner = nil
        }
        await settle()
        expect(connection.pending.count == 6, "six connection attempts are suspended")
        expect(connecting.compactMap(\.value).isEmpty, "hidden histories are released during connection discovery")
        connection.finish(true); await settle()
        expect(connecting.compactMap(\.value).isEmpty, "late connection completion is safe without a model")
        for (preconnected, isNew, result) in [(false,false,true),(false,false,false),(false,true,true),(true,false,true),(true,true,true)] {
            let socket = SyntheticSocket(); socket.isConnected = preconnected
            let owner = Subject(manager:nil,socket:socket); owner.isNew = isNew; owner.startupSocket(); await settle()
            socket.finish(result); await settle()
            expect(owner.logger.infos == (preconnected ? 0 : 1), "visible connection completion preserves logging")
            expect(owner.listenerStarts == ((!isNew && (preconnected || result)) ? 1 : 0), "passive listeners preserve new/existing and connection gates")
        }
        noManager.startupSocket(); await settle()
        expect(noManager.listenerStarts == 0, "missing socket does not register a listener")
        let paramsManager=ConversationManager()
        var hiddenParams:[WeakOwner]=[]
        for n in 1...6 {
            var owner:Subject?=Subject(manager:paramsManager,size:16*1024*1024,seed:UInt8(n))
            hiddenParams.append(WeakOwner(owner!));owner!.startupParams();await settle();owner=nil
        }
        expect(paramsManager.apiClient.pending.count==6,"six parameter requests are suspended")
        expect(hiddenParams.compactMap(\.value).isEmpty,"hidden histories are released during parameter discovery")
        paramsManager.apiClient.finish(.success(Params(defaultUploadContext:"invented-context",hasAnyOverride:true)));await settle()
        expect(hiddenParams.compactMap(\.value).isEmpty,"late parameter completion is safe after model release")
        for failed in [false,true] {
            let manager=ConversationManager(),owner=Subject(manager:manager)
            owner.attachments=[Attachment(uploadContext:nil),Attachment(uploadContext:"invented-existing")]
            owner.selectedKnowledgeItems=[Knowledge(context:nil),Knowledge(context:"invented-existing")]
            owner.startupParams();await settle()
            let params=Params(defaultUploadContext:"invented-new",hasAnyOverride:true)
            if failed { manager.apiClient.finish(.failure(NSError(domain:"org.example.synthetic",code:1))) } else { manager.apiClient.finish(.success(params)) }
            await owner.userDefaultParamsTask?.value
            expect(owner.activeChatStore?.cachedUserDefaultParams == (failed ? nil : params),"parameter cache success/failure is preserved")
            expect(owner.attachments.map(\.uploadContext)==[failed ? nil : "invented-new","invented-existing"],"attachment context defaults preserve explicit values")
            expect(owner.selectedKnowledgeItems.map(\.context)==[failed ? nil : "invented-new","invented-existing"],"knowledge context defaults preserve explicit values")
            expect(owner.approvalRestores==(failed ? 0 : 1),"tool approval defaults restore only after successful params")
            expect(owner.logger.errors==1,"parameter success/failure logging is preserved")
        }
        noManager.startupParams();await noManager.userDefaultParamsTask?.value
        expect(noManager.activeChatStore?.cachedUserDefaultParams==nil,"missing parameter manager is safe")
        let canceledManager=ConversationManager(),canceledOwner=Subject(manager:canceledManager)
        let request=Task { await canceledOwner.fetchUserDefaultParamsFromServer() }
        while canceledManager.apiClient.pending.isEmpty { await Task.yield() }
        request.cancel();canceledManager.apiClient.finish(.success(Params(defaultUploadContext:"invented-canceled",hasAnyOverride:true)))
        await request.value
        expect(canceledOwner.activeChatStore?.cachedUserDefaultParams==nil && canceledOwner.approvalRestores==0,"awaited parameter cancellation reaches the transport")
        expect(canceledOwner.logger.errors==1,"canceled parameter request retains failure behavior")
        print("\(checks - failures)/\(checks) synthetic terminal-discovery checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
