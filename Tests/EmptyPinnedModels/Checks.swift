import Foundation
import Darwin

@main struct Checks {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func expect(_ value: Bool, _ label: String) {
        checks += 1; if !value { failures += 1; print("FAIL: " + label) }
    }
    static func cpu() -> Double {
        var value=rusage();getrusage(0,&value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
    }
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--benchmark") {
            let api=SyntheticAPI(["ui":["models":["invented-alpha"]]]);api.delay=5
            let store=Store();let started=ProcessInfo.processInfo.systemUptime, beforeCPU=cpu()
            for _ in 0..<60 { let model=Subject(api,store);await model.fetchPinnedModels();await model.fetchMessageQueueSettingFromServer() }
            let result:[String:Any]=["chats":60,"requests":api.calls,"response_json_bytes":api.bytes,"simulated_request_delay_ms":5,"wall_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,"cpu_ms":(cpu()-beforeCPU)*1000]
            print(String(data:try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!);return
        }
        for settings:[String:Any] in [[:],["ui":NSNull()],["ui":[:]], ["ui":["models":["invented-alpha"]]], ["ui":["pinnedModels":[String]()]],["ui":["pinnedModels":["invented-alpha"]]]] {
            let api=SyntheticAPI(settings),store=Store()
            for _ in 0..<3 { let model=Subject(api,store);await model.fetchPinnedModels() }
            expect(api.calls==1,"one settings request across fresh models, including missing pin fields")
            expect(store.cachedPinnedModelIds != nil,"empty and populated pin lists are cached")
            let model=Subject(api,store);await model.fetchPinnedModels()
            expect(model.pinnedModelIds == store.cachedPinnedModelIds,"visible model adopts the session cache")
        }
        for value:Any in ["invented-invalid",7,[7],NSNull()] {
            let api=SyntheticAPI(["ui":["pinnedModels":value]]),store=Store(),model=Subject(nil,nil)
            model.manager=Manager(api);model.activeChatStore=store;model.pinnedModelIds=["invented-existing"]
            await model.fetchPinnedModels();await model.fetchPinnedModels()
            expect(model.pinnedModelIds==["invented-existing"],"malformed pin value preserves existing state")
            expect(store.cachedPinnedModelIds==nil && api.calls==2,"malformed response is not cached")
        }
        for value:Any in ["invented-invalid",7,[7]] {
            let api=SyntheticAPI(["ui":value]),store=Store(),model=Subject(api,store)
            model.pinnedModelIds=["invented-existing"]
            await model.fetchPinnedModels();await model.fetchPinnedModels()
            expect(model.pinnedModelIds==["invented-existing"],"malformed UI value preserves existing pins")
            expect(store.cachedPinnedModelIds==nil && api.calls==2,"malformed UI value is not cached")
        }
        let failed=SyntheticAPI([:]);failed.fail=true;let store=Store(),model=Subject(failed,store)
        await model.fetchPinnedModels();expect(store.cachedPinnedModelIds==nil,"failed request is not cached")
        failed.fail=false;await model.fetchPinnedModels();expect(store.cachedPinnedModelIds==[] && failed.calls==2,"failed request can retry successfully")
        let cached=Store();cached.cachedPinnedModelIds=["invented-edited"];let api=SyntheticAPI([:]),visible=Subject(api,cached)
        await visible.fetchPinnedModels();expect(api.calls==0 && visible.pinnedModelIds==["invented-edited"],"cached in-session pin edits bypass the request")
        let independent=Store();await Subject(api,independent).fetchPinnedModels();expect(api.calls==1 && independent.cachedPinnedModelIds==[],"another session cache remains independent")
        let noManager=Subject(nil,nil);await noManager.fetchPinnedModels();expect(noManager.pinnedModelIds.isEmpty,"missing manager is safe")
        let noStore=Subject(api,nil);await noStore.fetchPinnedModels();await noStore.fetchPinnedModels();expect(api.calls==3,"missing store does not invent a cache")
        for settings:[String:Any] in [[:],["ui":NSNull()],["ui":[:]], ["ui":["models":["invented-alpha"]]], ["ui":["enableMessageQueue":false]],["ui":["enableMessageQueue":true]]] {
            let api=SyntheticAPI(settings),store=Store()
            for _ in 0..<3 { let model=Subject(api,store);await model.fetchMessageQueueSettingFromServer() }
            expect(api.calls==1,"one queue preference request across fresh models")
            expect(store.cachedMessageQueueSetting != nil,"default and explicit queue preferences are cached")
            let model=Subject(api,store);await model.fetchMessageQueueSettingFromServer()
            expect(model.enableMessageQueue == store.cachedMessageQueueSetting,"visible model adopts queue cache")
        }
        for value:Any in ["invented-invalid",[7],NSNull()] {
            let api=SyntheticAPI(["ui":["enableMessageQueue":value]]),store=Store(),model=Subject(api,store)
            model.enableMessageQueue=true
            await model.fetchMessageQueueSettingFromServer();await model.fetchMessageQueueSettingFromServer()
            expect(model.enableMessageQueue,"malformed queue value preserves current state")
            expect(store.cachedMessageQueueSetting==nil && api.calls==2,"malformed queue value is not cached")
        }
        for value:Any in ["invented-invalid",7,[7]] {
            let api=SyntheticAPI(["ui":value]),store=Store(),model=Subject(api,store)
            model.enableMessageQueue=true
            await model.fetchMessageQueueSettingFromServer();await model.fetchMessageQueueSettingFromServer()
            expect(model.enableMessageQueue,"malformed UI preserves queue preference")
            expect(store.cachedMessageQueueSetting==nil && api.calls==2,"malformed UI is not cached for queue")
        }
        let absent=SyntheticAPI([:]),absentStore=Store(),absentModel=Subject(absent,absentStore)
        absentModel.pinnedModelIds=["invented-existing"];absentModel.enableMessageQueue=true
        await absentModel.fetchPinnedModels();await absentModel.fetchMessageQueueSettingFromServer()
        expect(absentModel.pinnedModelIds==["invented-existing"] && absentStore.cachedPinnedModelIds==["invented-existing"],"absent pin field caches the existing visible value")
        expect(absentModel.enableMessageQueue && absentStore.cachedMessageQueueSetting==true,"absent queue field caches the existing visible value")
        let queueAPI=SyntheticAPI([:]),queueStore=Store(),queueModel=Subject(queueAPI,queueStore)
        queueAPI.fail=true;await queueModel.fetchMessageQueueSettingFromServer()
        expect(queueStore.cachedMessageQueueSetting==nil,"failed queue request is not cached")
        queueAPI.fail=false;await queueModel.fetchMessageQueueSettingFromServer()
        expect(queueAPI.calls==2 && queueStore.cachedMessageQueueSetting==false,"failed queue request retries successfully")
        queueStore.cachedMessageQueueSetting=true;await Subject(queueAPI,queueStore).fetchMessageQueueSettingFromServer()
        expect(queueAPI.calls==2,"cached queue edits bypass a request")
        let otherQueueStore=Store();await Subject(queueAPI,otherQueueStore).fetchMessageQueueSettingFromServer()
        expect(queueAPI.calls==3 && otherQueueStore.cachedMessageQueueSetting==false,"another queue cache remains independent")
        await noManager.fetchMessageQueueSettingFromServer();expect(!noManager.enableMessageQueue,"missing queue manager is safe")
        let queueNoStore=Subject(queueAPI,nil);await queueNoStore.fetchMessageQueueSettingFromServer();await queueNoStore.fetchMessageQueueSettingFromServer()
        expect(queueAPI.calls==5,"missing queue store does not invent a cache")
        for queue in [false,true] {
            let api=SyntheticAPI([:]),store=Store(),model=Subject(api,store);api.hold=true
            let pending=Task { if queue { await model.fetchMessageQueueSettingFromServer() } else { await model.fetchPinnedModels() } }
            while api.waiters.isEmpty { await Task.yield() }
            store.clear();api.finish();await pending.value
            expect(store.cachedPinnedModelIds==nil && store.cachedMessageQueueSetting==nil,"late missing-field response does not refill an invalidated session")
            api.settings=["ui":["pinnedModels":["invented-new-session"],"enableMessageQueue":true]]
            if queue { await model.fetchMessageQueueSettingFromServer() } else { await model.fetchPinnedModels() }
            expect(api.calls==2 && (queue ? store.cachedMessageQueueSetting==true : store.cachedPinnedModelIds==["invented-new-session"]),"new cache generation fetches its own preference")
        }
        for queue in [false,true] {
            let api=SyntheticAPI([:]),store=Store(),model=Subject(api,store);api.hold=true
            let pending=Task { if queue { await model.fetchMessageQueueSettingFromServer() } else { await model.fetchPinnedModels() } }
            while api.waiters.isEmpty { await Task.yield() }
            store.cachedPinnedModelIds=["invented-concurrent-edit"];store.cachedMessageQueueSetting=true
            api.finish();await pending.value
            expect(store.cachedPinnedModelIds==["invented-concurrent-edit"] && store.cachedMessageQueueSetting==true,"late absent preference preserves concurrent cached edits")
            let current=Subject(api,store)
            if queue { await current.fetchMessageQueueSettingFromServer() } else { await current.fetchPinnedModels() }
            expect(api.calls==1 && (queue ? current.enableMessageQueue : current.pinnedModelIds==["invented-concurrent-edit"]),"new model reads the concurrent preference from cache")
        }
        print("\(checks-failures)/\(checks) synthetic absent-preference cache checks passed");exit(failures==0 ? 0 : 1)
    }
}
