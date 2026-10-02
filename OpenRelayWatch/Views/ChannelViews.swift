import SwiftUI
import WatchKit

struct ChannelsListView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List(store.snapshot.channels) { channel in
            NavigationLink(value: WatchRouter.Route.channel(id: channel.id, name: channel.name)) {
                Label(channel.name, systemImage: icon(channel.kind))
                    .lineLimit(2)
            }
        }
        .navigationTitle("Channels")
        .overlay {
            if store.snapshot.channels.isEmpty { Text("No channels").foregroundStyle(.secondary) }
        }
        .refreshable { await store.refresh() }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "dm": return "person.fill"
        case "group": return "person.2.fill"
        default: return "number"
        }
    }
}

/// Recent channel messages + post by dictation.
struct ChannelView: View {
    let channelId: String
    let name: String

    @State private var detail: WatchChannelDetail?
    @State private var error: String?
    @State private var isPosting = false
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: the input button must never be recycled while a
                // dictation sheet is open.
                VStack(alignment: .leading, spacing: 10) {
                    if let detail {
                        if detail.messages.isEmpty {
                            Text("No messages yet").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(detail.messages) { MessageBubble(message: $0) }
                        if detail.canPost {
                            if isPosting {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                DictationButton(title: "Message", systemImage: "square.and.pencil") { post($0) }
                            }
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Try Again") { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .onChange(of: detail?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(detail?.name ?? name)
        .task {
            await load()
            // Light live updates while the channel is open and the screen
            // is bright (paused in Always On to save battery).
            refreshTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if !isLuminanceReduced { await load() }
                }
            }
        }
        .onChange(of: isLuminanceReduced) { _, dimmed in
            if !dimmed { Task { await load() } }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private func load() async {
        do {
            let fresh = try await WatchLink.shared.request(.channel, WatchIdRequest(id: channelId), as: WatchChannelDetail.self, attempts: 2)
            error = nil
            detail = fresh
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }

    private func post(_ text: String) {
        isPosting = true
        Task {
            do {
                _ = try await WatchLink.shared.request(.postChannel, WatchPostRequest(channelId: channelId, text: text), as: WatchEmpty.self)
                WKInterfaceDevice.current().play(.success)
                await load()
            } catch {
                WKInterfaceDevice.current().play(.failure)
                self.error = error.localizedDescription
            }
            isPosting = false
        }
    }
}
