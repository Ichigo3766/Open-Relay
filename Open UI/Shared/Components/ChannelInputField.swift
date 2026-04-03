import SwiftUI
import PhotosUI

// MARK: - Channel Input Field
//
// Shared input component used by:
//   • ChannelDetailView  (main channel message input)
//   • ThreadDetailSheet  (thread reply input)
//
// Key features vs the raw PasteableTextView usage it replaces:
//   • Respects the "Send on Enter" user toggle (@AppStorage "sendOnEnter")
//   • Displays an attachment preview strip above the composer
//   • Provides an optional @mention trigger and #channel-link trigger
//   • Matches the same rounded-card visual style as ChatInputField

struct ChannelInputField: View {

    // MARK: - Required

    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    var placeholder: String = "Message"
    var isEnabled: Bool = true
    var onSend: () async -> Void
    var canSend: Bool

    // MARK: - Attachment callbacks

    var onAttachmentTapped: (() -> Void)?
    var onPasteAttachments: (([ChatAttachment]) -> Void)?
    var onRemoveAttachment: ((ChatAttachment) -> Void)?

    // MARK: - Mention / channel-link trigger callbacks

    var onAtTrigger: ((String) -> Void)?
    var onAtDismiss: (() -> Void)?
    var onHashTrigger: ((String) -> Void)?
    var onHashDismiss: (() -> Void)?

    // MARK: - Environment

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityScale) private var accessibilityScale

    // MARK: - User preference

    @AppStorage("sendOnEnter") private var sendOnEnter = true

    // MARK: - Font

    /// Base font size matching ChatInputField.
    private static let inputBaseFontSize: CGFloat = 14

    private var scaledInputFont: UIFont {
        let scale = accessibilityScale.scale(for: .content)
        let size = round(Self.inputBaseFontSize * scale * 10) / 10
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: size)
        }
        return base
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Attachment preview strip
            if !attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, 4)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Composer row
            HStack(alignment: .center, spacing: 8) {
                // Plus / attachment button
                if let onAttachmentTapped {
                    Button {
                        onAttachmentTapped()
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "plus")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1.0 : 0.4)
                }

                // Text input
                PasteableTextView(
                    text: $text,
                    placeholder: placeholder,
                    font: scaledInputFont,
                    textColor: UIColor(theme.textPrimary),
                    placeholderColor: UIColor(theme.textTertiary),
                    tintColor: UIColor(theme.brandPrimary),
                    isEnabled: isEnabled,
                    onPasteAttachments: { pasted in
                        withAnimation(.easeOut(duration: 0.15)) {
                            onPasteAttachments?(pasted)
                        }
                        Haptics.play(.light)
                    },
                    onSubmit: {
                        // Respect the sendOnEnter toggle: only send on Return when enabled
                        if sendOnEnter && canSend {
                            Task { await onSend() }
                        }
                    },
                    onHashTrigger: onHashTrigger,
                    onHashDismiss: onHashDismiss,
                    onAtTrigger: onAtTrigger,
                    onAtDismiss: onAtDismiss,
                    sendOnReturn: sendOnEnter
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(placeholder)

                // Send button
                if canSend {
                    Button {
                        Task { await onSend() }
                        Haptics.play(.light)
                    } label: {
                        Circle()
                            .fill(theme.brandPrimary)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "arrow.up")
                                    .scaledFont(size: 13, weight: .bold)
                                    .foregroundStyle(theme.brandOnPrimary)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(
            theme.isDark
                ? theme.cardBackground.opacity(0.95)
                : theme.inputBackground
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(
            color: .black.opacity(theme.isDark ? 0.2 : 0.06),
            radius: 8, x: 0, y: 2
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.2), value: attachments.count)
    }

    // MARK: - Attachment Strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
        }
    }

    private func attachmentThumbnail(_ attachment: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = attachment.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.surfaceContainer)
                    .frame(width: 50, height: 50)
                    .overlay(
                        VStack(spacing: 2) {
                            if attachment.isUploading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Text(attachment.name)
                                .scaledFont(size: 7)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    )
            }

            // Remove button
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    onRemoveAttachment?(attachment)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 16)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }
}
