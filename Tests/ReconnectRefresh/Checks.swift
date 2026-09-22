import Foundation

// Queue the production Task closures so tests can await all callback work.
@MainActor
struct Task {
    static var pending: [@MainActor () async -> Void] = []
    @discardableResult init(operation: @escaping @MainActor () async -> Void) {
        Self.pending.append(operation)
    }
    static func drain() async {
        while !pending.isEmpty { await pending.removeFirst()() }
    }
}

@MainActor
struct DispatchQueue {
    static let main = DispatchQueue()
    func async(execute: () -> Void) { execute() }
}

@MainActor final class Socket {
    var onConnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    func handshake(reconnectCount: Int) {
        // SOCKET_HANDSHAKE
    }
}

@MainActor final class Counter {
    var count = 0
    func refreshFolders() async { count += 1 }
    func refreshChannels() async { count += 1 }
    func refreshBackendConfig() async { count += 1 }
}

@MainActor final class ListModel {
    var count = 0
    let folderViewModel = Counter()
    func refreshIfStale() async { count += 1 }
}

@MainActor final class Chat {
    var isStreaming = false
    var syncs = 0
    func syncWithServer() async { syncs += 1 }
}

@MainActor final class Store {
    let chat = Chat()
    func viewModel(for id: String) -> Chat { chat }
}

@MainActor final class Dependencies {
    let socketService: Socket? = Socket()
    let activeChatStore = Store()
    let authViewModel = Counter()
}

@MainActor final class State {
    var hasRegisteredSocketHandlers = false
    var activeConversationId: String? = "synthetic-chat"
    let dependencies = Dependencies()
    let listViewModel = ListModel()
    let channelListVM = Counter()
}

@MainActor protocol Host {
    var state: State { get }
    func register()
}

extension Host {
    var hasRegisteredSocketHandlers: Bool {
        get { state.hasRegisteredSocketHandlers }
        nonmutating set { state.hasRegisteredSocketHandlers = newValue }
    }
    var activeConversationId: String? { state.activeConversationId }
    var dependencies: Dependencies { state.dependencies }
    var listViewModel: ListModel { state.listViewModel }
    var channelListVM: Counter { state.channelListVM }
}

@MainActor struct Phone: Host {
    let state = State()
    // PHONE_REGISTRATION
    func register() { registerSocketReconnectHandler() }
}

@MainActor struct Tablet: Host {
    let state = State()
    // TABLET_REGISTRATION
    func register() { registerSocketReconnectHandler() }
}

@main enum Checks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        for host in [Phone(), Tablet()] as [Host] {
            let tablet = host is Tablet
            let label = tablet ? "tablet" : "phone"
            host.register()
            host.register() // Registration is idempotent.
            let socket = host.dependencies.socketService!
            let chat = host.dependencies.activeChatStore.chat
            for connection in 0...3 {
                chat.isStreaming = connection == 2
                if connection == 3 { host.state.activeConversationId = nil }
                socket.handshake(reconnectCount: connection)
                await Task.drain()
                check(host.listViewModel.count == connection + 1, "\(label): one conversation refresh per connection")
                check(host.listViewModel.folderViewModel.count == connection + 1, "\(label): one folder refresh per connection")
                check(host.channelListVM.count == (tablet ? connection + 1 : 0), "\(label): channel refresh count")
                check(host.dependencies.authViewModel.count == (tablet ? connection : 0), "\(label): reconnect config refresh preserved")
                check(chat.syncs == (connection == 0 ? 0 : 1), "\(label): only active idle chat syncs on reconnect")
            }
        }
        if failures > 0 { exit(1) }
        print("PASS: phone/tablet initial connection, reconnect, streaming, no active chat, repeated registration")
    }
}
