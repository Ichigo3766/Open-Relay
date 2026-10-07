import SwiftUI

/// Read-only transcript used by the admin chat viewer. It renders messages with the same
/// building blocks as the main chat (markdown/tool-call renderer, user bubble, status steps,
/// authenticated images), fed the full server + sign-in details so nothing fails to load.
///
/// Performance: every message's display text (relative URLs, citations) is prepared ONCE
/// when the chat loads — not on every redraw — and rows live in a plain lazy stack.
struct ReadOnlyChatTranscript: View {
    let conversation: Conversation
    let ownerName: String?
    let serverBaseURL: String
    let apiClient: APIClient?

    @Environment(\.theme) var theme

    /// One prepared message: the text is already processed for display.
    struct Row: Identifiable {
        let id: String
        let message: ChatMessage
        let text: String
    }

    @State var rows: [Row] = []
    @State var copiedMessageId: String?
    @State var usageMessageId: String?
    @State var sourcesMessage: ChatMessage?
    @State private var scrollPosition = ScrollPosition()
    @State private var isScrolledAway = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ReadOnlyChatHeader(conversation: conversation, ownerName: ownerName)
                    ForEach(rows) { row in
                        messageRow(row)
                    }
                }
                .padding(.bottom, Spacing.lg)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > 120
            } action: { _, away in
                if away != isScrolledAway {
                    withAnimation(MicroAnimation.snappy) { isScrolledAway = away }
                }
            }

            if isScrolledAway {
                Button {
                    withAnimation(MicroAnimation.glide) { scrollPosition.scrollTo(edge: .bottom) }
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.down")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textInverse)
                        .frame(width: 36, height: 36)
                        .background(theme.textPrimary.opacity(0.8), in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.pressable)
                .padding(.trailing, Spacing.screenPadding)
                .padding(.bottom, Spacing.lg)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .task(id: conversation.id) { prepareRows() }
        .sheet(item: $sourcesMessage) { message in
            SourcesDetailSheet(sources: message.sources)
        }
    }

    // MARK: - Preparation (once per chat)

    private func prepareRows() {
        let base = serverBaseURL
        rows = conversation.messages.map { message in
            guard message.role == .assistant else {
                return Row(id: message.id, message: message, text: message.content)
            }
            let resolved = Self.resolveRelativeURLs(message.content, baseURL: base)
            return Row(id: message.id, message: message,
                       text: Self.preprocessCitations(resolved, sources: message.sources))
        }
    }

    static func resolveRelativeURLs(_ content: String, baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, content.contains("](/api/"),
              let regex = try? NSRegularExpression(pattern: #"(\]\()(/api/[^\s\)]+)"#) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "$1\(base)$2")
    }

    static func preprocessCitations(_ content: String, sources: [ChatSourceReference]) -> String {
        guard !sources.isEmpty, let regex = try? NSRegularExpression(pattern: #"\[(\d+)\](?!\()"#) else { return content }
        let ns = content as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let number = ns.substring(with: match.range(at: 1))
            if let index = Int(number), index >= 1, index <= sources.count,
               let url = sources[index - 1].resolvedURL, !url.isEmpty {
                result += " [\(index)](\(url)) "
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
