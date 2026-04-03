import SwiftUI

// MARK: - Message Reaction Overlay

/// iMessage-style floating reaction picker + action menu shown on long-press.
/// Displays a scrollable emoji strip above the message and action buttons below.
struct MessageReactionOverlay: View {
    let message: ChannelMessage
    let isCurrentUser: Bool
    let onReaction: (String) -> Void
    let onReply: () -> Void
    let onThread: (() -> Void)?
    let onPin: () -> Void
    let onCopy: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onMoreEmoji: () -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    
    /// Quick reaction emojis shown in the horizontal strip
    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            
            VStack(spacing: 8) {
                Spacer()
                
                // Emoji reaction strip
                HStack(spacing: 8) {
                    ForEach(quickEmojis, id: \.self) { emoji in
                        Button {
                            onReaction(emoji)
                            Haptics.play(.light)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // More emoji button → opens full picker
                    Button {
                        onMoreEmoji()
                    } label: {
                        Image(systemName: "face.smiling")
                            .scaledFont(size: 20, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.88, anchor: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                
                // Action menu
                VStack(spacing: 0) {
                    actionButton(icon: "arrowshape.turn.up.left", label: "Reply") { onReply() }
                    if let onThread {
                        Divider().padding(.leading, 44)
                        actionButton(icon: "bubble.left.and.bubble.right", label: "Reply in Thread") { onThread() }
                    }
                    Divider().padding(.leading, 44)
                    actionButton(icon: message.isPinned ? "pin.slash" : "pin", label: message.isPinned ? "Unpin" : "Pin") { onPin() }
                    Divider().padding(.leading, 44)
                    actionButton(icon: "doc.on.doc", label: "Copy") { onCopy() }
                    
                    if let onEdit {
                        Divider().padding(.leading, 44)
                        actionButton(icon: "pencil", label: "Edit") { onEdit() }
                    }
                    
                    if let onDelete {
                        Divider().padding(.leading, 44)
                        actionButton(icon: "trash", label: "Delete", isDestructive: true) { onDelete() }
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, Spacing.screenPadding)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .move(edge: .bottom)).combined(with: .opacity),
                    removal: .opacity
                ))
                
                Spacer()
            }
            .padding(.vertical, 60)
        }
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity
        ))
    }
    
    private func actionButton(icon: String, label: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onDismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(isDestructive ? theme.error : theme.textPrimary)
                    .frame(width: 24)
                Text(label)
                    .scaledFont(size: 15, weight: .regular)
                    .foregroundStyle(isDestructive ? theme.error : theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
