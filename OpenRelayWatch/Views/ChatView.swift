import SwiftUI

/// An existing chat: last messages, then reply by dictation.
struct ChatView: View {
    let chatId: String
    let title: String

    @Environment(WatchStore.self) private var store
    @State private var detail: WatchChatDetail?
    @State private var error: String?
    @State private var turn: TurnController

    init(chatId: String, title: String) {
        self.chatId = chatId
        self.title = title
        _turn = State(initialValue: TurnController(chatId: chatId, chatTitle: title))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: the input button must never be recycled while a
                // dictation sheet is open.
                VStack(alignment: .leading, spacing: 10) {
                    if let detail {
                        if detail.truncated {
                            Text("Earlier messages are on your iPhone.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(detail.messages) { MessageBubble(message: $0) }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Try Again") { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if turn.phase != .idle { TurnContentView(turn: turn) }
                    if !turn.isBusy {
                        if !turn.followUps.isEmpty {
                            ChipsView(items: turn.followUps.map { ($0, $0) }, systemImage: "arrow.turn.down.right") { text in
                                commitTurn()
                                turn.ask(text, modelId: nil, speak: store.speakReplies)
                            }
                        }
                        DictationButton(title: "Reply", systemImage: "arrowshape.turn.up.left.fill") { text in
                            commitTurn()
                            turn.ask(text, modelId: nil, speak: store.speakReplies)
                        }
                        NavigationLink(value: WatchRouter.Route.talk(chatId: chatId, title: detail?.title ?? title)) {
                            Label("Talk", systemImage: "waveform")
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .onChange(of: detail?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: turn.phase) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(detail?.title ?? title)
        .handoff(chatId: chatId)
        .toolbar {
            if turn.isBusy || turn.isSpeaking {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop.fill") { turn.cancel() }
                }
            }
        }
        .task { await load() }
        .onDisappear { turn.cancel() }
    }

    /// Moves the finished turn into the message list before the next one.
    private func commitTurn() {
        guard turn.phase == .done, let prompt = turn.prompt, var detail else { return }
        let now = Date()
        detail.messages.append(WatchMessage(id: "u\(now.timeIntervalSince1970)", role: "user", author: nil, text: prompt, date: now))
        detail.messages.append(WatchMessage(id: "a\(now.timeIntervalSince1970)", role: "assistant", author: nil, text: turn.reply, date: now))
        self.detail = detail
    }

    private func load() async {
        error = nil
        do {
            detail = try await WatchLink.shared.request(.chat, WatchIdRequest(id: chatId), as: WatchChatDetail.self)
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }
}

struct MessageBubble: View {
    let message: WatchMessage

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
            if let author = message.author {
                Text(author).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(message.role == "user" ? .footnote : .body)
                .padding(message.role == "assistant" ? 0 : 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch message.role {
        case "user": return "You: \(message.text)"
        case "other": return "\(message.author ?? "Someone"): \(message.text)"
        default: return "Assistant: \(message.text)"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case "user": return Color.accentColor.opacity(0.3)
        case "other": return Color.gray.opacity(0.25)
        default: return .clear
        }
    }
}

struct ChatsListView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List(store.snapshot.chats) { chat in
            NavigationLink(value: WatchRouter.Route.chat(id: chat.id, title: chat.title)) {
                ChatRow(chat: chat)
            }
        }
        .navigationTitle("Chats")
        .overlay {
            if store.snapshot.chats.isEmpty { Text("No chats yet").foregroundStyle(.secondary) }
        }
        .refreshable { await store.refresh() }
    }
}
