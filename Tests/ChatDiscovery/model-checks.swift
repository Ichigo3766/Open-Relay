import Foundation
struct Model:Sendable {let id:String;func resolveAvatarURL(baseURL:URL?)->URL?{nil}}
struct Logger:Sendable {func error(_ text:String){}}
struct APIClient:Sendable {let network=Network()}
struct Network:Sendable {let authToken:String?=nil}
actor Transport {
    var delay:Duration = .milliseconds(80)
    var defaultDelay:Duration = .milliseconds(80)
    var modelFails=false
    var defaultId:String?="invented-preferred"
    func models() async throws->[Model]{try await Task.sleep(for:delay);if modelFails{throw URLError(.cannotConnectToHost)};return [Model(id:"invented-first"),Model(id:"invented-preferred")]}
    func preferred() async ->String?{let delay=defaultDelay,id=defaultId;return await Task.detached {try? await Task.sleep(for:delay);return id}.value}
    func slowDefaultFailure(){delay = .milliseconds(10);defaultDelay = .seconds(2);modelFails=true}
    func configure(fails:Bool,id:String?){modelFails=fails;defaultId=id}
}
struct Manager:Sendable {let transport:Transport;let apiClient=APIClient();func fetchModels()async throws->[Model]{try await transport.models()};func fetchDefaultModel()async->String?{await transport.preferred()}}
@MainActor final class Store {var cachedDefaultModelId:String?;var models=[Model]();func updateModelCache(models:[Model],selectedId:String?){self.models=models}}
actor ImageCacheService {static let shared=ImageCacheService();func evict(for:URL){};func prefetchWithAuth(urls:[URL],authToken:String?) {}}
@MainActor final class Subject {
    var manager:Manager?;var isLoadingModels=false;var availableModels=[Model]();var selectedModelId:String?;var activeChatStore:Store?=Store();let logger=Logger();var serverBaseURL:URL?;var syncs=0
    func syncUIWithModelDefaults(){syncs+=1}
    INSERT_METHOD
}
@main struct Checks {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ ok:Bool,_ label:String){checks+=1;if !ok{print("FAIL: "+label);exit(1)}}
        let transport=Transport();let subject=Subject();subject.manager=Manager(transport:transport)
        let begin=ContinuousClock.now;await subject.loadModels();let elapsed=Double(begin.duration(to:.now).components.attoseconds)/1e18+Double(begin.duration(to:.now).components.seconds)
        check(subject.selectedModelId=="invented-preferred","server default wins over first model")
        check(subject.activeChatStore?.cachedDefaultModelId=="invented-preferred","server default cached")
        check(subject.activeChatStore?.models.count==2,"model cache populated")
        check(!subject.isLoadingModels && subject.syncs==1,"loading finishes with one defaults sync")
        subject.selectedModelId="invented-existing";await subject.loadModels();check(subject.selectedModelId=="invented-existing","existing chat selection preserved")
        subject.selectedModelId=nil;await transport.configure(fails:false,id:nil);await subject.loadModels();check(subject.selectedModelId=="invented-first","missing default falls back")
        let cachedCount=subject.availableModels.count;await transport.configure(fails:true,id:"invented-other");await subject.loadModels();check(subject.availableModels.count==cachedCount,"model failure retains cached list");check(!subject.isLoadingModels,"failure ends loading")
        subject.manager=nil;let syncs=subject.syncs;await subject.loadModels();check(subject.syncs==syncs,"unconfigured load performs no work")
        subject.manager=Manager(transport:transport);await transport.slowDefaultFailure()
        let failureStart=ContinuousClock.now;await subject.loadModels()
        let failureDuration=failureStart.duration(to:.now)
        let failureSeconds=Double(failureDuration.components.seconds)+Double(failureDuration.components.attoseconds)/1e18
        check(failureSeconds<0.5,"failed model list does not await an unrelated slow shared default lookup")
        print("Passed \(checks) model discovery checks; delayed discovery wall \(elapsed) seconds")
    }
}
