import SwiftUI

// MARK: - Actions

extension ReadOnlyChatTranscript {

    /// Copy (icon becomes a checkmark), plus Usage when the server stored token counts.
    func actionBar(_ message: ChatMessage) -> some View {
        HStack(spacing: Spacing.xs) {
            let copied = copiedMessageId == message.id
            Button { copy(message) } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(copied ? theme.brandPrimary : theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Copy")

            if let usage = message.usage, !usage.isEmpty {
                Button { usageMessageId = message.id } label: {
                    Image(systemName: "info.circle")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Usage")
                .popover(isPresented: Binding(
                    get: { usageMessageId == message.id },
                    set: { if !$0 { usageMessageId = nil } }
                ), arrowEdge: .bottom) {
                    UsageInfoPopover(usage: usage)
                        .themed()
                        .presentationCompactAdaptation(.popover)
                }
            }

            Spacer(minLength: 0)
            Text(message.timestamp.chatTimestamp)
                .scaledFont(size: 10)
                .foregroundStyle(theme.textTertiary.opacity(0.6))
                .padding(.trailing, 6)
        }
    }

    func copy(_ message: ChatMessage) {
        UIPasteboard.general.string = message.content
        Haptics.notify(.success)
        withAnimation(MicroAnimation.quick) { copiedMessageId = message.id }
        let id = message.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedMessageId == id {
                withAnimation(MicroAnimation.quick) { copiedMessageId = nil }
            }
        }
    }

    static func shortModelName(_ full: String) -> String {
        if let slash = full.lastIndex(of: "/") { return String(full[full.index(after: slash)...]) }
        if let colon = full.lastIndex(of: ":") { return String(full[..<colon]) }
        return full
    }
}

// MARK: - Header

/// Owner, message count, model and date, at the top of the transcript.
struct ReadOnlyChatHeader: View {
    let conversation: Conversation
    let ownerName: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                pill("bubble.left.and.text.bubble.right", "\(conversation.messages.count) messages")
                if let model = conversation.model {
                    pill("cpu", ReadOnlyChatTranscript.shortModelName(model))
                }
                pill("calendar", conversation.createdAt.chatTimestamp)
            }
            if let ownerName {
                Text("Chat by \(ownerName)")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.md)
    }

    private func pill(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).scaledFont(size: 10, weight: .medium)
            Text(text).scaledFont(size: 11, weight: .medium).lineLimit(1)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(Capsule())
    }
}
