import Foundation
import CryptoKit
enum TLSChallengeHandler { static func isClientCertificateError(_ error:Error)->Bool { false } }

enum FixtureStorage {
    static let directory=URL(fileURLWithPath:CommandLine.arguments[1])
    static let suite="relay-discovery-fixture-"+UUID().uuidString
    static let defaults=UserDefaults(suiteName:suite)!
}
struct ConversationIndex: Codable {}
enum CachedConversationSnapshot { static let marker="openrelay_cache_compact";static func compact(_ data:Data)->Data? { nil } }
// INSERT_CACHE
struct AIModel: @unchecked Sendable {
    let id:String;var profileImageURL:String?;var rawModelItem:[String:Any]
    func resolveAvatarURL(baseURL:String?) -> URL? { URL(string:"https://relay.example.test/avatar/"+id) }
}
enum NamedModelControl { static func decode(_ data:Data,locales:[String])->[String:[String]] { [:] } }
enum LocalizedContent { static func deviceLocaleCandidates()->[String] { ["en"] } }
struct Logger {func error(_ value:String) {};func info(_ value:String) {};func warning(_ value:String) {}}
@MainActor final class Network {
    var conversationCacheScope:String?="synthetic-account-a";var headers=[String:String]();var delay:Duration = .milliseconds(80);var fail=false;var requests=0;var authToken:String?="invented-session"
    var data=Data("{\"data\":[{\"id\":\"invented-first\"},{\"id\":\"invented-default\",\"pipe\":{\"id\":\"fixture-pipe\"},\"info\":{\"meta\":{\"input_schema\":{\"required\":[\"color\"]}}}}]}".utf8)
    func requestRaw(path:String) async throws -> (Data,HTTPURLResponse) {
        requests+=1;try await Task.sleep(for:delay);if fail { throw URLError(.notConnectedToInternet) }
        return (data,HTTPURLResponse(url:URL(string:"https://relay.example.test"+path)!,statusCode:200,httpVersion:nil,headerFields:headers)!)
    }
}
@MainActor final class APIClient {
    var settingsFail=false
    var userFinished=false;var configOverlapped=false
    var user=User(role:.user);var configDelay:Duration = .milliseconds(80)
    func getCurrentUser() async throws -> User { userFinished=false;try await Task.sleep(for:configDelay);userFinished=true;return user }
    func getBackendConfig() async throws -> Bool { configOverlapped = !userFinished;try await Task.sleep(for:configDelay);return true }
    func updateAuthToken(_ value:String?) { network.authToken=value }
    let network=Network();var preferred:String?="invented-default"
    func parseModelArray(_ rows:[[String:Any]],controls:[String:[String]])->[AIModel] {
        rows.compactMap { item in (item["id"] as? String).map { AIModel(id:$0,profileImageURL:item["avatar"] as? String,rawModelItem:item) } }
    }
    func getUserSettings() async throws -> [String:Any] {
        network.requests+=1;try await Task.sleep(for:network.delay);if settingsFail { throw URLError(.timedOut) };if network.fail { throw URLError(.notConnectedToInternet) }
        return ["ui":["models":preferred.map { [$0] } ?? []]]
    }
// INSERT_API
}
@MainActor final class Store {
    var generation=UUID();var cachedDefaultModelId:String?;var models=[AIModel]()
    func updateModelCache(models:[AIModel],selectedId:String?) { self.models=models }
}
@MainActor final class Manager {
    let apiClient:APIClient;init(_ apiClient:APIClient) { self.apiClient=apiClient }
    func fetchModels() async throws -> [AIModel] { try await apiClient.getModels() }
    func fetchDefaultModel() async -> String? { await apiClient.getDefaultModel() }
}
actor ImageCacheService {
    static let shared=ImageCacheService();var evictions=[URL]();var prefetches=0
    func evict(for url:URL) { evictions.append(url) }
    func prefetchWithAuth(urls:[URL],authToken:String?) { prefetches+=urls.count }
}
@MainActor final class Subject {
    var manager:Manager?;var activeChatStore:Store?=Store();var availableModels=[AIModel]();var selectedModelId:String?;var serverBaseURL:String?="https://relay.example.test";let logger=Logger()
    var isLoadingModels=false;var hasLoaded=false;var conversationId:String?;var syncs=0;var conversationLoads=0
    func syncUIWithModelDefaults() { syncs+=1 }
    func loadConversation() async { conversationLoads+=1 }
// INSERT_LOAD
// INSERT_MODELS
}
struct User {enum Role {case user,pending};var role:Role;var displayName="Invented Fixture"}
@MainActor final class AuthSubject {
    struct Dependencies {let apiClient:APIClient?};struct ConfigStore {let activeServer:Bool?=true}
    enum Phase {case restoringSession,authenticated,pendingApproval,authMethodSelection,serverConnection}
    var dependencies:Dependencies?;let serverConfigStore=ConfigStore();var currentUser:User?;var backendConfig:Bool?;var errorMessage:String?;var phase=Phase.restoringSession;let logger=Logger();var socketConnects=0
    func ensureBackendConfig() async {backendConfig=true};func connectSocketWithToken(){socketConnects+=1};func cacheCurrentUser(){};func saveCurrentUserAsAccount(){};func startTokenRefreshTimer(){}
// INSERT_AUTH
}
@main struct Checks {
    @MainActor static func main() async throws {
        defer { try? FileManager.default.removeItem(at:FixtureStorage.directory);FixtureStorage.defaults.removePersistentDomain(forName:FixtureStorage.suite) }
        try? FileManager.default.removeItem(at:FixtureStorage.directory)
        var total=0;var failures=0
        func check(_ ok:Bool,_ name:String) { total+=1;if !ok { failures+=1;print("FAIL: "+name) } }
        let api=APIClient();let initial=Subject();initial.manager=Manager(api)
        await initial.load();check(initial.selectedModelId=="invented-default","first load selects actual server default")
        check(initial.availableModels.count==2 && initial.activeChatStore?.models.count==2,"first fetch populates both model lists")
        let cached=await api.cachedModelDiscovery();check(cached?.models.count==2,"model metadata survives view model recreation")
        check(cached?.defaultId=="invented-default","server default survives recreation")
        check((cached?.models.last?.rawModelItem["pipe"] as? [String:Any])?["id"] as? String == "fixture-pipe","cached pipe model retains model_item")
        check(cached?.models.last?.rawModelItem["info"] != nil,"cached required-input metadata survives")
        let start=ContinuousClock.now;api.network.delay = .seconds(2)
        let cold=Subject();cold.manager=Manager(api);await cold.load();let wall=start.duration(to:.now)
        check(wall < .milliseconds(500),"cached cold load does not await slow network")
        check(cold.availableModels.count==2 && cold.selectedModelId=="invented-default","cached first frame has models and default")
        let existing=Subject();existing.manager=Manager(api);existing.selectedModelId="invented-existing";existing.conversationId="synthetic-chat";await existing.load()
        check(existing.selectedModelId=="invented-existing" && existing.conversationLoads==1,"existing chat preserves its selected model")
        print("Synthetic cached discovery wall: \(wall)")
        api.network.conversationCacheScope="synthetic-account-b"
        check(await api.cachedModelDiscovery()==nil,"different account cannot read cached discovery")
        api.network.conversationCacheScope=nil;check(await api.cachedModelDiscovery()==nil,"signed-out context has no discovery cache")
        api.network.conversationCacheScope="synthetic-account-a";api.network.delay = .milliseconds(5);api.network.fail=true
        let models=cold.availableModels;await cold.loadModels();check(cold.availableModels.count==models.count && !cold.isLoadingModels,"offline refresh preserves cached models and clears loading")
        api.network.fail=false;api.network.headers=["Cache-Control":"no-store"];_=try await api.getModels()
        check(await api.cachedModelDiscovery()==nil,"no-store evicts saved model metadata")
        api.network.headers=[:];_=try await api.getModels();api.network.headers=["Vary":"*"];_=try await api.getModels()
        check(await api.cachedModelDiscovery()==nil,"Vary star evicts saved model metadata")
        api.network.headers=[:];api.network.data=Data("[{\"id\":\"array-model\"}]".utf8)
        check(try await api.getModels().first?.id=="array-model","bare model arrays decode")
        api.network.data=Data("{\"models\":[{\"id\":\"nested-model\"}]}".utf8)
        check(try await api.getModels().first?.id=="nested-model","models wrapper decodes")
        api.network.data=Data("{\"data\":[]}".utf8);_=try await api.getModels()
        check(await api.cachedModelDiscovery()==nil,"empty discovery is not seeded as a second background fetch")
        api.network.data=Data("{\"models\":[{\"id\":\"nested-model\"}]}".utf8);_=try await api.getModels()
        api.preferred=nil;_=await api.getDefaultModel();check(await api.cachedModelDiscovery()?.defaultId==nil,"absent default replaces prior value")
        let revision=await ConversationCache.shared.currentRevision();await ConversationCache.shared.clear()
        await ConversationCache.shared.saveMetadata(Data("stale".utf8),scope:"synthetic-account-a",id:"models",revision:revision)
        check(await api.cachedModelDiscovery()==nil,"clearing cache rejects older in-flight metadata writes")
        FixtureStorage.defaults.setVolatileDomain([ConversationCache.limitKey:0],forName:UserDefaults.argumentDomain)
        _=try await api.getModels();check(await api.cachedModelDiscovery()==nil,"disabled cache does not persist discovery")
        FixtureStorage.defaults.setVolatileDomain([ConversationCache.limitKey:1],forName:UserDefaults.argumentDomain)
        let r=await ConversationCache.shared.currentRevision();await ConversationCache.shared.saveMetadata(Data((0..<2*1024*1024).map { _ in UInt8.random(in:0...255) }),scope:"synthetic-account-a",id:"oversized",revision:r)
        check(await ConversationCache.shared.cachedMetadata(scope:"synthetic-account-a",id:"oversized")==nil,"metadata obeys existing byte budget")
        api.network.delay = .milliseconds(50);let raced=Subject();raced.manager=Manager(api)
        let load=Task { await raced.loadModels() };try? await Task.sleep(for:.milliseconds(10));raced.activeChatStore?.generation=UUID();await load.value
        check(raced.activeChatStore?.models.isEmpty==true && !raced.isLoadingModels,"old-account fetch cannot populate replacement session cache")
        check(await ImageCacheService.shared.prefetches==0,"model loads do not prefetch every avatar")
        let avatar=Subject();let avatarAPI=APIClient();avatar.manager=Manager(avatarAPI)
        avatar.availableModels=[AIModel(id:"invented-first",profileImageURL:"old-image",rawModelItem:[:])]
        avatarAPI.network.data=Data("{\"data\":[{\"id\":\"invented-first\",\"avatar\":\"new-image\"}]}".utf8)
        let evictions=await ImageCacheService.shared.evictions.count;await avatar.loadModels();try? await Task.sleep(for:.milliseconds(5))
        check(await ImageCacheService.shared.evictions.count==evictions+1,"changed avatar metadata invalidates the old image")
        await avatar.loadModels();try? await Task.sleep(for:.milliseconds(5))
        check(await ImageCacheService.shared.evictions.count==evictions+1,"unchanged avatars remain cached")
        let authAPI=APIClient();let auth=AuthSubject();auth.dependencies=AuthSubject.Dependencies(apiClient:authAPI)
        let begin=ContinuousClock.now;await auth.restoreSession();let authWall=begin.duration(to:.now)
        check(auth.phase == .authenticated && auth.socketConnects==1,"restoration authenticates and starts socket once")
        check(authAPI.configOverlapped,"independent user/config requests overlap")
        print("Synthetic two 80 ms restore requests: \(authWall)")
        authAPI.user=User(role:.pending);await auth.restoreSession();check(auth.phase == .pendingApproval,"pending user is not authenticated")
        let selectionAPI=APIClient();selectionAPI.network.conversationCacheScope="selection-"+UUID().uuidString
        let automatic=Subject();automatic.manager=Manager(selectionAPI);automatic.availableModels=models
        automatic.selectedModelId="invented-first";automatic.activeChatStore?.cachedDefaultModelId="invented-first"
        await automatic.loadModels();check(automatic.selectedModelId=="invented-default","fresh server default replaces an unchanged cached default for a new chat")
        automatic.conversationId="existing-chat";automatic.selectedModelId="invented-first";automatic.activeChatStore?.cachedDefaultModelId="invented-first"
        await automatic.loadModels();check(automatic.selectedModelId=="invented-first","default refresh never changes an existing chat's model")
        automatic.conversationId=nil;automatic.selectedModelId="invented-first";automatic.activeChatStore?.cachedDefaultModelId="invented-default";selectionAPI.preferred="invented-default"
        await automatic.loadModels();check(automatic.selectedModelId=="invented-first","default refresh preserves a different user selection")
        automatic.selectedModelId="invented-default";automatic.activeChatStore?.cachedDefaultModelId="invented-default"
        let refresh=Task { await automatic.loadModels() };try? await Task.sleep(for:.milliseconds(10));automatic.selectedModelId="invented-first";await refresh.value
        check(automatic.selectedModelId=="invented-first","selection made during refresh is preserved")
        selectionAPI.settingsFail=true
        check(await selectionAPI.getDefaultModel()=="invented-default","temporary settings failure retains the last acknowledged default")
        selectionAPI.network.conversationCacheScope="selection-other-account"
        check(await selectionAPI.getDefaultModel()==nil,"default fallback cannot read another account's metadata")
        print("Passed \(total-failures)/\(total) cold startup checks")
        if failures>0 { exit(1) }
    }
}
