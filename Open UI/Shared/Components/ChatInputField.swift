import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - Chat Attachment

private struct AttachmentID: Identifiable {
    let id: UUID
}

struct ChatAttachment: Identifiable {
    let id = UUID()
    let type: AttachmentType
    let name: String
    var thumbnail: Image?
    var data: Data?

    /// Whether this audio attachment is currently being transcribed.
    var isTranscribing: Bool = false

    /// The transcribed text from an audio attachment (set after ASR processing).
    var transcribedText: String?

    // MARK: - Upload & Processing State

    /// Current upload/processing status for this attachment.
    var uploadStatus: UploadStatus = .pending

    /// The server-assigned file ID after successful upload + processing.
    var uploadedFileId: String?

    /// The full server-response object returned by the files API after upload.
    /// Used to build rich file references matching the web UI payload format.
    var uploadedFileObject: [String: Any]?

    /// When `true`, the full extracted text is injected into the request payload
    /// (`data.content`) and `"context": "full"` is added to the file ref.
    /// When `false` (default), focused RAG retrieval is used.
    var useFullContext: Bool = false

    /// Error message if upload or processing failed.
    var uploadError: String?

    /// Whether this attachment is still being uploaded or processed.
    var isUploading: Bool {
        switch uploadStatus {
        case .uploading, .processing: return true
        default: return false
        }
    }

    /// Whether this attachment is ready to be sent (uploaded + processed).
    var isReady: Bool {
        uploadStatus == .completed && uploadedFileId != nil
    }

    enum AttachmentType: Sendable {
        case image
        case file
        case audio
    }

    enum UploadStatus: Sendable {
        case pending      // Not yet started
        case uploading    // Uploading to server
        case processing   // Server is processing (text extraction, embeddings)
        case completed    // Ready to use
        case error        // Upload or processing failed
    }
}

// MARK: - Chat Input Field

struct ChatInputField: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    var placeholder: String = "Message"
    var isEnabled: Bool = true
    var onSend: () -> Void
    var onStopGenerating: (() -> Void)?

    // Tools menu bindings
    @Binding var webSearchEnabled: Bool
    @Binding var imageGenerationEnabled: Bool
    @Binding var codeInterpreterEnabled: Bool
    var isWebSearchAvailable: Bool = true
    var isImageGenerationAvailable: Bool = true
    var isCodeInterpreterAvailable: Bool = true
    var tools: [ToolItem]
    @Binding var selectedToolIds: Set<String>
    var isLoadingTools: Bool = false
    /// True once tools have been fetched at least once from the server.
    /// Used to distinguish "never fetched" (show pills) from "fetched and tool gone" (hide pill).
    var toolsHaveLoaded: Bool = false

    // Terminal bindings
    var terminalEnabled: Bool = false
    var isTerminalAvailable: Bool = false
    var terminalServerName: String = ""
    var availableTerminalServers: [TerminalServer] = []
    var onTerminalToggle: (() -> Void)?
    var onTerminalServerSelected: ((TerminalServer) -> Void)?
    var onBrowseFiles: (() -> Void)?

    // Model mention bindings (@ trigger)
    @Binding var mentionedModel: AIModel?
    var mentionedModelImageURL: URL?
    var mentionedModelAuthToken: String?
    var onAtTrigger: ((String) -> Void)?
    var onAtDismiss: (() -> Void)?

    // Knowledge base bindings
    @Binding var selectedKnowledgeItems: [KnowledgeItem]
    // Reference chat bindings
    @Binding var selectedReferenceChats: [ReferenceChatItem]
    // Notes bindings
    @Binding var selectedNotes: [Note]
    var onHashTrigger: ((String) -> Void)?
    var onHashDismiss: (() -> Void)?

    // Prompt slash command bindings (/ trigger)
    var onSlashTrigger: ((String) -> Void)?
    var onSlashDismiss: (() -> Void)?

    // Skills bindings ($ trigger)
    var onDollarTrigger: ((String) -> Void)?
    var onDollarDismiss: (() -> Void)?

    // Attachment callbacks
    var onFileAttachment: (() -> Void)?
    var onPhotoAttachment: (() -> Void)?
    var onCameraCapture: (() -> Void)?
    var onWebAttachment: (() -> Void)?
    var onReferenceChatAttachment: (() -> Void)?
    var onFilesAttachment: (() -> Void)?
    var onNotesAttachment: (() -> Void)?
    var onKnowledgeAttachment: (() -> Void)?
    var onVoiceInput: (() -> Void)?

    // Data sources for inline attach pickers (passed through to ToolsMenuSheet)
    var apiClient: APIClient? = nil
    var notesManager: NotesManager? = nil
    var conversationManager: ConversationManager? = nil
    /// Called when the user selects files from the inline files picker.
    var onFilesSelected: (([ChatAttachment]) -> Void)? = nil

    // Skills
    var skills: [SkillItem] = []
    @Binding var selectedSkillIds: [String]
    var isLoadingSkills: Bool = false

    // Dictation
    var onDictationStart: (() -> Void)?
    var onDictationStop: (() -> Void)?
    var onDictationCancel: (() -> Void)?
    var isDictating: Bool = false
    /// Pass the live DictationService so the overlay can observe it directly.
    var dictationService: DictationService? = nil
    /// Called when the tools/overflow sheet is about to appear.
    var onToolsSheetPresented: (() -> Void)?

    /// Called when the user taps the valves gear icon on a tool that has user-configurable valves.
    /// `id` = tool/function ID, `isFunction` = whether it's a function (vs. a tool).
    var onOpenToolUserValves: ((String, Bool) -> Void)?

    /// Optional custom photo picker view (SwiftUI PhotosPicker).
    var photoPicker: AnyView?

    // Message queue bindings
    var messageQueue: [QueuedMessage] = []
    var onQueueSendNow: ((UUID) -> Void)? = nil
    var onQueueEdit: ((UUID) -> Void)? = nil
    var onQueueDelete: ((UUID) -> Void)? = nil

    // MARK: - Tool Permissions (Human-in-the-Loop)
    /// Whether the server admin has enabled Tool Permissions.
    /// When true a "Tool Permissions" entry appears in the + sheet.
    var isToolPermissionsEnabled: Bool = false
    /// Current tool approval mode, passed through to `ToolsMenuSheet`.
    var toolApprovalMode: String = "full"
    /// Called when the user changes the mode in the + sheet.
    var onToolApprovalModeChange: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityScale) private var accessibilityScale
    @FocusState private var isFocused: Bool

    /// UI chrome scale (buttons, icons, touch targets) — mirrors AccessibilityManager.uiScale.
    private var uiScale: CGFloat { accessibilityScale.scale(for: .ui) }
    @State private var showToolsSheet = false
    @State private var previewingAttachmentId: AttachmentID? = nil

    // MARK: - Expand-to-compose state (Slack-style swipe-up)
    @State private var composerIsExpanded = false
    @State private var composerExpandDrag: CGFloat = 0
    private let composerExpandedHeight: CGFloat = 220
    private let composerCollapsedHeight: CGFloat = 44  // approx natural height
    private var composerCurrentHeight: CGFloat? {
        guard composerIsExpanded else { return nil }
        return max(120, composerExpandedHeight + composerExpandDrag)
    }

    /// Quick pills preference from UserDefaults
    @AppStorage("quickPills") private var quickPillsData: String = ""

    /// Whether any audio attachment is still being transcribed.
    private var isTranscribing: Bool {
        attachments.contains { $0.type == .audio && $0.isTranscribing }
    }

    /// Whether any attachment is still uploading or being processed on the server.
    private var hasUploadingAttachments: Bool {
        attachments.contains { $0.isUploading }
    }

    private var canSend: Bool {
        isEnabled && !isTranscribing && !hasUploadingAttachments &&
            (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    /// Whether any tool/feature is currently active.
    private var hasActiveFeatures: Bool {
        webSearchEnabled || !selectedToolIds.isEmpty
    }

    /// Saved quick pill IDs from settings.
    private var savedQuickPillIds: [String] {
        guard !quickPillsData.isEmpty else { return [] }
        return quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    private var hasQuickPills: Bool {
        !activeQuickPills.isEmpty
    }

    /// Whether the voice icon button should appear in the pills row.
    private var showBottomVoiceButton: Bool {
        onVoiceInput != nil && isEnabled && !canSend && hasQuickPills
    }

    var body: some View {
        VStack(spacing: 0) {
            if isDictating || dictationService?.state == .processing, let svc = dictationService {
                // Dictation active — replace entire composer with recording bar
                DictationOverlayView(
                    service: svc,
                    onStop: { onDictationStop?() },
                    onCancel: { onDictationCancel?() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                // Normal composer
                VStack(spacing: 0) {
                    // Message queue strip
                    if !messageQueue.isEmpty {
                        MessageQueueView(
                            queue: messageQueue,
                            onSendNow: { id in onQueueSendNow?(id) },
                            onEdit: { id in onQueueEdit?(id) },
                            onDelete: { id in onQueueDelete?(id) }
                        )
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.bottom, Spacing.xs)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    // Attachment previews
                    if !attachments.isEmpty {
                        attachmentStrip
                            .padding(.horizontal, Spacing.screenPadding)
                            .padding(.bottom, Spacing.xs)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    // Composer
                    composerShell
                        .padding(.horizontal, Spacing.screenPadding)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDictating)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dictationService?.state == .processing)
        // Widget deep link — focus the text field and show keyboard when
        // the user taps the "New Chat" action button on the home screen widget.
        .onReceive(NotificationCenter.default.publisher(for: .chatInputFieldRequestFocus)) { _ in
            isFocused = true
        }
        .sheet(isPresented: $showToolsSheet) {
            ToolsMenuSheet(
                webSearchEnabled: $webSearchEnabled,
                imageGenerationEnabled: $imageGenerationEnabled,
                codeInterpreterEnabled: $codeInterpreterEnabled,
                isWebSearchAvailable: isWebSearchAvailable,
                isImageGenerationAvailable: isImageGenerationAvailable,
                isCodeInterpreterAvailable: isCodeInterpreterAvailable,
                tools: tools,
                selectedToolIds: $selectedToolIds,
                isLoadingTools: isLoadingTools,
                onFileAttachment: onFileAttachment,
                onPhotoAttachment: onPhotoAttachment,
                onCameraCapture: onCameraCapture,
                onWebAttachment: onWebAttachment,
                onFilesAttachment: onFilesAttachment,
                onNotesAttachment: onNotesAttachment,
                onKnowledgeAttachment: onKnowledgeAttachment,
                onReferenceChatAttachment: onReferenceChatAttachment,
                apiClient: apiClient,
                notesManager: notesManager,
                conversationManager: conversationManager,
                selectedNotes: $selectedNotes,
                selectedKnowledgeItems: $selectedKnowledgeItems,
                selectedReferenceChats: $selectedReferenceChats,
                onFilesSelected: onFilesSelected,
                photoPicker: photoPicker,
                onOpenToolUserValves: onOpenToolUserValves,
                isNotesEnabled: true,
                skills: skills,
                selectedSkillIds: $selectedSkillIds,
                isLoadingSkills: isLoadingSkills,
                isToolPermissionsEnabled: isToolPermissionsEnabled,
                toolApprovalMode: toolApprovalMode,
                onToolApprovalModeChange: onToolApprovalModeChange
            )
        }
        .onChange(of: showToolsSheet) { _, isPresented in
            if isPresented { onToolsSheetPresented?() }
        }
        // When tools finish loading, prune any starred IDs that no longer exist.
        // This permanently removes orphaned favorites caused by deleted/removed tools
        // so they never reappear in the quick-pills row.
        .onChange(of: isLoadingTools) { _, isLoading in
            guard !isLoading else { return }
            let knownBuiltins: Set<String> = ["web", "image"]
            let knownToolIds = Set(tools.map { $0.id })
            let current = quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
            let pruned = current.filter { id in
                knownBuiltins.contains(id) || knownToolIds.contains(id)
            }
            if pruned.count != current.count {
                quickPillsData = pruned.joined(separator: ",")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: attachments.count)
        .sheet(item: $previewingAttachmentId) { wrapper in
            AttachmentPreviewSheet(attachments: $attachments, attachmentId: wrapper.id)
        }
    }

    // MARK: - Expand gesture for composer
    private var composerExpandGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dy = value.translation.height  // negative = upward
                if composerIsExpanded {
                    // Dragging down → shrink live
                    composerExpandDrag = max(-composerExpandedHeight + 80, -dy)
                } else {
                    // Dragging up → peek
                    if dy < 0 { composerExpandDrag = dy }
                }
            }
            .onEnded { value in
                let dy = value.translation.height
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    if composerIsExpanded {
                        let newH = composerExpandedHeight - dy
                        if newH < 100 {
                            composerIsExpanded = false
                            Haptics.play(.light)
                        }
                    } else {
                        if dy < -50 {
                            composerIsExpanded = true
                            isFocused = true
                            Haptics.play(.light)
                        }
                    }
                    composerExpandDrag = 0
                }
            }
    }

    // MARK: - Composer Shell

    private var composerShell: some View {
        VStack(spacing: 0) {
            // Invisible full-coverage tap target so tapping anywhere on the
            // composer (including padding areas) focuses the text field.
            // Uses the existing widget-focus notification that PasteInterceptingTextView
            // already observes, so no new coupling is needed.
            Color.clear
                .frame(height: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                }
            // Model override chip (above text input)
            if mentionedModel != nil {
                mentionedModelChip
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Knowledge items chips (above text input)
            if !selectedKnowledgeItems.isEmpty {
                knowledgeChipsStrip
                    .padding(.horizontal, 10)
                    .padding(.top, mentionedModel != nil ? 4 : 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Reference chat chips (above text input)
            if !selectedReferenceChats.isEmpty {
                referenceChatChipsStrip
                    .padding(.horizontal, 10)
                    .padding(.top, (mentionedModel != nil || !selectedKnowledgeItems.isEmpty) ? 4 : 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Note chips (above text input)
            if !selectedNotes.isEmpty {
                noteChipsStrip
                    .padding(.horizontal, 10)
                    .padding(.top, (mentionedModel != nil || !selectedKnowledgeItems.isEmpty || !selectedReferenceChats.isEmpty) ? 4 : 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Main text input row — center alignment keeps + and send/voice
            // button symmetrically aligned with the text on all line counts.
            // The trailing buttons are grouped into a single fixed-size HStack
            // so SwiftUI treats them as one atomic block and allocates their
            // space first; the text field fills whatever remains.
            HStack(alignment: composerIsExpanded ? .top : .center, spacing: 8) {
                inlinePlusButton
                    .padding(.top, composerIsExpanded ? 6 : 0)
                textField
                    .frame(height: composerIsExpanded ? composerCurrentHeight : nil, alignment: .top)
                    .fixedSize(horizontal: false, vertical: !composerIsExpanded)
                HStack(spacing: 8) {
                    inlineTerminalButton
                    inlineDictationButton
                    trailingButton
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, composerIsExpanded ? 6 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, (selectedKnowledgeItems.isEmpty && selectedReferenceChats.isEmpty && selectedNotes.isEmpty && mentionedModel == nil) ? 10 : 6)
            .padding(.bottom, hasQuickPills ? 6 : 10)

            // Quick pills row (only when pills are configured)
            if hasQuickPills {
                pillsRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                .strokeBorder(composerBorderColor, lineWidth: 0.5)
        )
        // Subtle shadow — upward only, no competing directions
        .shadow(
            color: theme.isDark
                ? Color.black.opacity(isFocused ? 0.3 : 0.2)
                : Color.black.opacity(isFocused ? 0.1 : 0.06),
            radius: 8,
            x: 0,
            y: 2
        )
        .gesture(composerExpandGesture)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: composerIsExpanded)
        .animation(.interactiveSpring(), value: composerExpandDrag)
    }

    private var composerCornerRadius: CGFloat {
        // Shrink corners slightly for multiline content
        text.contains("\n") || text.count > 60 ? 18 : 22
    }

    private var composerBackground: Color {
        theme.isDark
            ? theme.cardBackground.opacity(0.95)
            : theme.inputBackground
    }

    private var composerBorderColor: Color {
        isFocused
            ? theme.brandPrimary.opacity(0.35)
            : theme.cardBorder.opacity(0.4)
    }

    // MARK: - Inline Plus Button

    private var inlinePlusButton: some View {
        Button {
            Haptics.play(.light)
            isFocused = false
            showToolsSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        hasActiveFeatures
                            ? theme.brandPrimary.opacity(0.12)
                            : Color.clear
                    )
                    .frame(width: 28 * uiScale, height: 28 * uiScale)

                Image(systemName: "plus")
                    .scaledFont(size: 15 * uiScale, weight: .semibold)
                    .foregroundStyle(hasActiveFeatures ? theme.brandPrimary : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
        .accessibilityLabel("Attachments & tools")
        .animation(.easeInOut(duration: 0.15), value: hasActiveFeatures)
    }

    // MARK: - Text Field

    @AppStorage("sendOnEnter") private var sendOnEnter = true

    /// Base font size for the chat input field.
    private static let inputBaseFontSize: CGFloat = 14

    /// Rounded system font scaled by the user's accessibility content scale.
    private var scaledInputFont: UIFont {
        let scale = accessibilityScale.scale(for: .input)
        let size = round(Self.inputBaseFontSize * scale * 10) / 10
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: size)
        }
        return base
    }

    private var textField: some View {
        PasteableTextView(
            text: $text,
            placeholder: placeholder,
            font: scaledInputFont,
            textColor: UIColor(theme.textPrimary),
            placeholderColor: UIColor(theme.textTertiary),
            tintColor: UIColor(theme.brandPrimary),
            isEnabled: isEnabled,
            onPasteAttachments: { pastedAttachments in
                withAnimation(.easeOut(duration: 0.15)) {
                    attachments.append(contentsOf: pastedAttachments)
                }
                Haptics.play(.light)
            },
            onSubmit: {
                if sendOnEnter && canSend {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        composerIsExpanded = false
                        composerExpandDrag = 0
                    }
                    onSend()
                }
            },
            onHashTrigger: onHashTrigger,
            onHashDismiss: onHashDismiss,
            onAtTrigger: onAtTrigger,
            onAtDismiss: onAtDismiss,
            onSlashTrigger: onSlashTrigger,
            onSlashDismiss: onSlashDismiss,
            onDollarTrigger: onDollarTrigger,
            onDollarDismiss: onDollarDismiss,
            sendOnReturn: sendOnEnter
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(placeholder)
    }

    // MARK: - Inline Terminal Button

    /// Compact terminal icon that sits inline in the text row.
    /// - Single server: tap toggles on/off
    /// - Multiple servers: tap opens a Menu for server selection
    @ViewBuilder
    private var inlineTerminalButton: some View {
        if isTerminalAvailable, let onTerminalToggle {
            let hasMultiple = availableTerminalServers.count > 1

            if hasMultiple {
                Menu {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                        Haptics.play(.light)
                    } label: {
                        Label(
                            terminalEnabled ? "Disable Terminal" : "Enable Terminal",
                            systemImage: terminalEnabled ? "xmark.circle" : "checkmark.circle"
                        )
                    }

                    if terminalEnabled, let onBrowseFiles {
                        Button {
                            onBrowseFiles()
                            Haptics.play(.light)
                        } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                    }

                    Divider()

                    ForEach(availableTerminalServers) { server in
                        Button {
                            onTerminalServerSelected?(server)
                            if !terminalEnabled {
                                withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                            }
                            Haptics.play(.light)
                        } label: {
                            HStack {
                                Text(server.displayName)
                                if server.id == (availableTerminalServers.first(where: { $0.displayName == terminalServerName })?.id ?? "") {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    terminalIconLabel
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .animation(.easeInOut(duration: 0.15), value: terminalEnabled)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                    Haptics.play(.light)
                } label: {
                    terminalIconLabel
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .animation(.easeInOut(duration: 0.15), value: terminalEnabled)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// The compact circular terminal icon used in the inline position.
    private var terminalIconLabel: some View {
        Circle()
            .fill(
                terminalEnabled
                    ? theme.brandPrimary.opacity(0.12)
                    : Color.clear
            )
            .frame(width: 26 * uiScale, height: 26 * uiScale)
            .overlay(
                Image(systemName: "terminal")
                    .scaledFont(size: 11 * uiScale, weight: .semibold)
                    .foregroundStyle(
                        terminalEnabled
                            ? theme.brandPrimary
                            : theme.textTertiary
                    )
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        terminalEnabled
                            ? theme.brandPrimary.opacity(0.4)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.4)
            .accessibilityLabel("Terminal")
            .accessibilityValue(terminalEnabled ? "Enabled" : "Disabled")
    }

    // MARK: - Inline Dictation Button

    /// Mic icon button that starts/stops dictation.
    /// Shown only when `onDictationStart` is wired up.
    @ViewBuilder
    private var inlineDictationButton: some View {
        if onDictationStart != nil {
            Button {
                Haptics.play(.medium)
                onDictationStart?()
            } label: {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 26 * uiScale, height: 26 * uiScale)
                    .overlay(
                        Image(systemName: "mic")
                            .scaledFont(size: 12 * uiScale, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1.0 : 0.4)
            .accessibilityLabel("Start dictation")
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Trailing Button (Send / Stop / Voice)

    private var trailingButton: some View {
        Group {
            if onStopGenerating != nil && !canSend {
                // Stop generating — only shown when there is no text to queue
                Button {
                    Haptics.play(.light)
                    onStopGenerating?()
                } label: {
                    Circle()
                        .fill(theme.error.opacity(0.15))
                        .frame(width: 26 * uiScale, height: 26 * uiScale)
                        .overlay(
                            Image(systemName: "stop.fill")
                                .scaledFont(size: 10 * uiScale, weight: .bold)
                                .foregroundStyle(theme.error)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop Generating")
                .transition(.scale.combined(with: .opacity))

            } else if canSend {
                // Send message (or queue it when streaming + message queue is enabled)
                // Send message
                Button {
                    Haptics.play(.light)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        composerIsExpanded = false
                        composerExpandDrag = 0
                    }
                    onSend()
                } label: {
                    Circle()
                        .fill(theme.brandPrimary)
                        .frame(width: 26 * uiScale, height: 26 * uiScale)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .scaledFont(size: 11 * uiScale, weight: .bold)
                                .foregroundStyle(theme.brandOnPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send message")
                .transition(.scale.combined(with: .opacity))

            } else if !hasQuickPills, let onVoiceInput {
                // Voice button — only in inline position when no pill row exists
                Button {
                    Haptics.play(.light)
                    onVoiceInput()
                } label: {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.brandPrimary.opacity(0.5),
                                    theme.brandPrimary.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 26 * uiScale, height: 26 * uiScale)
                        .overlay(
                            Image(systemName: "waveform")
                                .scaledFont(size: 11 * uiScale, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voice call")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }

    // MARK: - Pills Row

    private var pillsRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeQuickPills, id: \.id) { pill in
                        pillButton(pill)
                    }
                }
            }

            Spacer(minLength: 0)

            // Voice icon button (no text label) in pill row position
            if showBottomVoiceButton, let onVoiceInput {
                Button {
                    Haptics.play(.light)
                    onVoiceInput()
                } label: {
                    Image(systemName: "waveform")
                        .scaledFont(size: 13 * uiScale, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 30 * uiScale, height: 26 * uiScale)
                        .background(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            theme.brandPrimary.opacity(0.5),
                                            theme.brandPrimary.opacity(0.2)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Voice call")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showBottomVoiceButton)
    }

    // MARK: - Quick Pills

    private var activeQuickPills: [QuickPill] {
        var pills: [QuickPill] = []

        for id in savedQuickPillIds {
            switch id {
            case "web":
                if isWebSearchAvailable {
                    pills.append(QuickPill(
                        id: "web",
                        icon: "magnifyingglass",
                        label: "Web",
                        isActive: webSearchEnabled,
                        action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                webSearchEnabled.toggle()
                            }
                            Haptics.play(.light)
                        }
                    ))
                }
            case "image":
                // Image Generation is a native feature toggle, not a tool.
                // Sync the pill with imageGenerationEnabled so it matches
                // the toggle in the tools sheet.
                if isImageGenerationAvailable {
                    pills.append(QuickPill(
                        id: "image",
                        icon: "photo",
                        label: "Image",
                        isActive: imageGenerationEnabled,
                        action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                imageGenerationEnabled.toggle()
                            }
                            Haptics.play(.light)
                        }
                    ))
                }
            default:
                // Show the pill while tools are still loading (transient absence),
                // but once loading is complete, only show it if the tool still exists.
                // This removes orphaned favorites for tools that have been deleted.
                let tool = tools.first(where: { $0.id == id })
                if toolsHaveLoaded && tool == nil {
                    // Tools have been fetched and this ID isn't among them — it's an
                    // orphan (tool was deleted/removed). Skip rendering the pill.
                    // Note: we guard on toolsHaveLoaded (not !isLoadingTools) to
                    // distinguish "never fetched yet" from "fetched and tool is gone".
                    continue
                }
                let displayName = tool?.name ?? id.replacingOccurrences(of: "_", with: " ").capitalized
                let isSelected = selectedToolIds.contains(id)
                pills.append(QuickPill(
                    id: id,
                    icon: "wrench",
                    label: displayName,
                    isActive: isSelected,
                    action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if isSelected {
                                selectedToolIds.remove(id)
                            } else {
                                selectedToolIds.insert(id)
                            }
                        }
                        Haptics.play(.light)
                    }
                ))
            }
        }

        return pills
    }

    private func pillButton(_ pill: QuickPill) -> some View {
        Button(action: pill.action) {
            HStack(spacing: 4) {
                Image(systemName: pill.icon)
                    .scaledFont(size: 11, weight: .semibold)
                Text(pill.label)
                    .scaledFont(size: 12, weight: pill.isActive ? .semibold : .medium)
            }
            .foregroundStyle(pill.isActive ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        pill.isActive
                            ? theme.brandPrimary.opacity(0.12)
                            : theme.surfaceContainer.opacity(0.6)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        pill.isActive
                            ? theme.brandPrimary.opacity(0.4)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.15), value: pill.isActive)
    }

    // MARK: - Mentioned Model Chip

    private var mentionedModelChip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if let model = mentionedModel {
                    ModelAvatar(
                        size: 18,
                        imageURL: mentionedModelImageURL,
                        label: model.shortName,
                        authToken: mentionedModelAuthToken
                    )
                }
                Text(mentionedModel?.shortName ?? "")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        mentionedModel = nil
                    }
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.brandPrimary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5)
            )

            Spacer()
        }
    }

    // MARK: - Note Chips Strip

    private var noteChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedNotes) { item in
                    noteChip(item)
                }
            }
        }
    }

    private func noteChip(_ item: Note) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "note.text")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text("Note")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.surfaceContainer.opacity(0.8)))
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedNotes.removeAll { $0.id == item.id }
                }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.brandPrimary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Reference Chat Chips Strip

    private var referenceChatChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedReferenceChats) { item in
                    referenceChatChip(item)
                }
            }
        }
    }

    private func referenceChatChip(_ item: ReferenceChatItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "bubble.left.and.bubble.right")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text("Chat")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.surfaceContainer.opacity(0.8)))
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedReferenceChats.removeAll { $0.id == item.id }
                }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.brandPrimary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Knowledge Chips Strip

    private var knowledgeChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedKnowledgeItems) { item in
                    knowledgeChip(item)
                }
            }
        }
    }

    private func knowledgeChip(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.iconName)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(item.name)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(item.typeBadge)
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(theme.surfaceContainer.opacity(0.8))
                )
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedKnowledgeItems.removeAll { $0.id == item.id }
                }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(theme.brandPrimary.opacity(0.08))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Attachment Strip

    /// Modern horizontal attachment strip — taller image tiles with upload ring,
    /// wider file/audio pill cards, and a +N overflow badge for 5+ images.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentTile(attachment)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5, anchor: .bottomLeading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.7, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        ))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    /// Single tile — image tiles are square 76×76, file/audio are wider pill cards.
    private func attachmentTile(_ attachment: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment.type {
                case .image:
                    imageTile(attachment)
                case .audio:
                    audioPillCard(attachment)
                case .file:
                    filePillCard(attachment)
                }
            }

            // Remove button — top-right corner
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    attachments.removeAll { $0.id == attachment.id }
                }
                Haptics.play(.light)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 20, height: 20)
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }

    // MARK: Image Tile (76×76 square with upload ring overlay)

    @ViewBuilder
    private func imageTile(_ attachment: ChatAttachment) -> some View {
        let isError = attachment.uploadStatus == .error
        let isUploading = attachment.isUploading
        let isDone = attachment.uploadStatus == .completed

        ZStack {
            if let thumbnail = attachment.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.surfaceContainer)
                    .frame(width: 76, height: 76)
                    .overlay(
                        Image(systemName: "photo")
                            .scaledFont(size: 22)
                            .foregroundStyle(theme.textTertiary)
                    )
            }

            // Upload state overlay
            if isError {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 76, height: 76)
                    .overlay(
                        Button {
                            NotificationCenter.default.post(
                                name: .retryAttachmentUpload,
                                object: attachment.id
                            )
                            Haptics.play(.light)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .scaledFont(size: 20)
                                    .foregroundStyle(.white)
                                Text("Retry")
                                    .scaledFont(size: 9, weight: .semibold)
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    )
            } else if isUploading {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 76, height: 76)
                    .overlay(
                        UploadRingView(color: .white)
                            .frame(width: 28, height: 28)
                    )
            } else if isDone {
                // Subtle green checkmark badge in corner on upload complete
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.success)
                            .background(Circle().fill(Color.black.opacity(0.4)).padding(2))
                            .padding(5)
                    }
                }
                .frame(width: 76, height: 76)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isError ? theme.error.opacity(0.8) : theme.cardBorder.opacity(0.25),
                    lineWidth: isError ? 1.5 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !isUploading, !isError else { return }
            Haptics.play(.light)
            previewingAttachmentId = AttachmentID(id: attachment.id)
        }
    }

    // MARK: Audio Pill Card

    @ViewBuilder
    private func audioPillCard(_ attachment: ChatAttachment) -> some View {
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        let isServerMode = audioFileMode == "server"
        let hasTranscript = attachment.transcribedText != nil
        let isError = attachment.uploadStatus == .error
        let isComplete = attachment.uploadStatus == .completed || hasTranscript
        let isUploading = attachment.isUploading || attachment.isTranscribing

        HStack(spacing: 10) {
            // Icon area
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isError ? theme.error.opacity(0.15)
                        : isComplete ? theme.success.opacity(0.12)
                        : theme.brandPrimary.opacity(0.12)
                    )
                    .frame(width: 44, height: 44)

                if isUploading {
                    UploadRingView(color: isServerMode ? theme.brandPrimary : theme.textSecondary)
                        .frame(width: 22, height: 22)
                } else if isError {
                    Button {
                        NotificationCenter.default.post(
                            name: .retryAttachmentUpload,
                            object: attachment.id
                        )
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(theme.error)
                    }
                    .buttonStyle(.plain)
                } else if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.success)
                } else {
                    Image(systemName: "waveform")
                        .scaledFont(size: 18)
                        .foregroundStyle(theme.brandPrimary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(isError ? theme.error : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(
                    isError ? "Upload failed" :
                    isUploading ? (isServerMode ? "Uploading…" : "Transcribing…") :
                    isComplete ? "Ready" :
                    "Audio"
                )
                .scaledFont(size: 10)
                .foregroundStyle(isError ? theme.error.opacity(0.7) : theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .frame(minWidth: 160, maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isError ? theme.error.opacity(0.5)
                    : isComplete ? theme.success.opacity(0.3)
                    : theme.cardBorder.opacity(0.4),
                    lineWidth: 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !isUploading else { return }
            Haptics.play(.light)
            previewingAttachmentId = AttachmentID(id: attachment.id)
        }
    }

    // MARK: File Pill Card

    private func filePillCard(_ attachment: ChatAttachment) -> some View {
        let isError = attachment.uploadStatus == .error
        let isUploading = attachment.isUploading
        let isReady = attachment.isReady
        let fileExt = (attachment.name as NSString).pathExtension.lowercased()
        let iconName = fileIconNameForExt(fileExt)
        let accentColor = fileAccentColor(for: fileExt)

        return HStack(spacing: 10) {
            // Icon area
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isError ? theme.error.opacity(0.15)
                        : isReady ? theme.success.opacity(0.10)
                        : accentColor.opacity(0.12)
                    )
                    .frame(width: 44, height: 44)

                if isUploading {
                    UploadRingView(color: accentColor)
                        .frame(width: 22, height: 22)
                } else if isError {
                    Button {
                        NotificationCenter.default.post(
                            name: .retryAttachmentUpload,
                            object: attachment.id
                        )
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(theme.error)
                    }
                    .buttonStyle(.plain)
                } else if isReady {
                    Image(systemName: iconName)
                        .scaledFont(size: 18)
                        .foregroundStyle(theme.success)
                } else {
                    Image(systemName: iconName)
                        .scaledFont(size: 18)
                        .foregroundStyle(accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(isError ? theme.error : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if !fileExt.isEmpty {
                        Text(fileExt.uppercased())
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.surfaceContainer.opacity(0.8)))
                    }
                    Text(
                        isError ? "Failed" :
                        isUploading ? "Uploading…" :
                        isReady ? "Ready" :
                        "Processing…"
                    )
                    .scaledFont(size: 10)
                    .foregroundStyle(
                        isError ? theme.error.opacity(0.7)
                        : isReady ? theme.success.opacity(0.8)
                        : theme.textTertiary
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .frame(minWidth: 160, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isError ? theme.error.opacity(0.5)
                    : isReady ? theme.success.opacity(0.3)
                    : theme.cardBorder.opacity(0.4),
                    lineWidth: 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !isUploading else { return }
            Haptics.play(.light)
            previewingAttachmentId = AttachmentID(id: attachment.id)
        }
    }

    // MARK: File Icon & Color Helpers

    private func fileIconNameForExt(_ ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.stack"
        case "json", "yaml", "yml", "xml", "conf", "toml", "ini": return "curlybraces"
        case "txt", "md", "rtf": return "doc.plaintext"
        case "js", "ts", "py", "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        default: return "doc"
        }
    }

    private func fileAccentColor(for ext: String) -> Color {
        switch ext {
        case "pdf": return Color.red
        case "doc", "docx": return Color.blue
        case "xls", "xlsx", "csv": return Color.green
        case "ppt", "pptx": return Color.orange
        case "json", "yaml", "yml", "xml": return Color.purple
        case "txt", "md", "rtf": return Color.gray
        case "zip", "tar", "gz", "rar", "7z": return Color.yellow
        default: return theme.brandPrimary
        }
    }
}

// MARK: - Upload Ring View

/// A compact spinning ring shown while an attachment is uploading.
private struct UploadRingView: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Quick Pill Model

private struct QuickPill: Identifiable {
    let id: String
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
}

// MARK: - Attachment Preview Sheet

/// Universal preview sheet for any attachment type.
/// - **Image**: shows a zoomable full-size preview from the thumbnail or data.
/// - **Audio**: shows the transcribed text (same as old TranscriptPreviewSheet).
/// - **File**: shows extracted content tab + original file preview tab (PDF or text),
///   plus a "Using Focused Retrieval" toggle that controls whether full document context
///   is injected into the send payload.
struct AttachmentPreviewSheet: View {
    /// Binding to the full attachments array so we can write `useFullContext` back.
    @Binding var attachments: [ChatAttachment]
    /// ID of the attachment being previewed.
    let attachmentId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    // MARK: - File content state
    @State private var selectedTab: FilePreviewTab = .content
    @State private var extractedContent: String? = nil
    @State private var extractedLineCount: Int = 0
    @State private var fileSize: Int64 = 0
    @State private var isLoadingContent: Bool = false
    @State private var loadError: String? = nil
    /// Raw bytes downloaded from the server for the Preview tab.
    @State private var downloadedFileData: Data? = nil
    @State private var isLoadingPreview: Bool = false

    enum FilePreviewTab: String, CaseIterable {
        case content = "Content"
        case preview = "Preview"
    }

    /// Convenience accessor — returns the current attachment from the binding.
    private var attachment: ChatAttachment {
        attachments.first(where: { $0.id == attachmentId }) ?? ChatAttachment(
            type: .file, name: "Unknown"
        )
    }

    /// Index into the binding array, used for mutations.
    private var attachmentIndex: Int? {
        attachments.firstIndex(where: { $0.id == attachmentId })
    }

    var body: some View {
        NavigationStack {
            Group {
                switch attachment.type {
                case .image:
                    imagePreview
                case .audio:
                    audioPreview
                case .file:
                    filePreviewWithTabs
                }
            }
            .background(theme.background)
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.brandPrimary)
                }
                // Copy button for content tab
                if attachment.type == .file, selectedTab == .content,
                   let content = extractedContent, !content.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            UIPasteboard.general.string = content
                            Haptics.play(.light)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if attachment.type == .file, let fileId = attachment.uploadedFileId {
                await loadFileInfo(fileId: fileId)
            }
        }
    }

    // MARK: - Load File Info

    private func loadFileInfo(fileId: String) async {
        guard let apiClient = dependencies.apiClient else { return }
        isLoadingContent = true
        loadError = nil
        do {
            let info = try await apiClient.getFileInfo(id: fileId)
            // Parse data.content (extracted text)
            if let dataDict = info["data"] as? [String: Any],
               let content = dataDict["content"] as? String {
                extractedContent = content
                extractedLineCount = content.components(separatedBy: "\n").count
            }
            // Parse meta.size
            if let meta = info["meta"] as? [String: Any],
               let size = meta["size"] as? Int {
                fileSize = Int64(size)
            } else if let localData = attachment.data {
                fileSize = Int64(localData.count)
            }
        } catch {
            loadError = error.localizedDescription
            if let localData = attachment.data {
                fileSize = Int64(localData.count)
            }
        }
        isLoadingContent = false

        // Download raw file bytes for the Preview tab (unless we already have local data).
        if attachment.data == nil {
            isLoadingPreview = true
            do {
                let (data, _) = try await apiClient.getFileContent(id: fileId)
                downloadedFileData = data
            } catch {
                // Preview will gracefully show "unavailable"
            }
            isLoadingPreview = false
        }
    }

    // MARK: - Image Preview

    @ViewBuilder
    private var imagePreview: some View {
        if let thumbnail = attachment.thumbnail {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else if let data = attachment.data, let uiImage = UIImage(data: data) {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else {
            ContentUnavailableView(
                "No Preview",
                systemImage: "photo",
                description: Text("Image preview is not available.")
            )
            .padding(.top, 60)
        }
    }

    // MARK: - Audio Preview

    @ViewBuilder
    private var audioPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let text = attachment.transcribedText, !text.isEmpty {
                    Text(text)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                } else {
                    ContentUnavailableView(
                        "No Transcript",
                        systemImage: "waveform.slash",
                        description: Text("This audio file has no transcribed text.")
                    )
                    .padding(.top, 60)
                }
            }
        }
        .toolbar {
            if let text = attachment.transcribedText, !text.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.play(.light)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .foregroundStyle(theme.brandPrimary)
                }
            }
        }
    }

    // MARK: - File Preview (tabbed)

    @ViewBuilder
    private var filePreviewWithTabs: some View {
        VStack(spacing: 0) {
            fileMetaHeader
            Divider()

            Picker("Tab", selection: $selectedTab) {
                ForEach(FilePreviewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if selectedTab == .content {
                contentTab
            } else {
                previewTab
            }
        }
    }

    // MARK: - File Meta Header

    private var fileMetaHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: icon + file info
            HStack(spacing: 12) {
                Image(systemName: fileIcon)
                    .scaledFont(size: 28)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if fileSize > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        if extractedLineCount > 0 {
                            Text("•")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                            Text("\(extractedLineCount) Extracted Lines")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        if isLoadingContent {
                            ProgressView().controlSize(.mini)
                        }
                    }

                    if extractedContent != nil {
                        Text("Formatting may be inconsistent from source.")
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                            .italic()
                    }
                }

                Spacer()
            }

            // Toggle row — only shown once file is ready
            if attachment.isReady {
                HStack {
                    Spacer()
                    Text(attachment.useFullContext ? "Using Entire Document" : "Using Focused Retrieval")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                    Toggle("", isOn: Binding(
                        get: { attachment.useFullContext },
                        set: { newValue in
                            guard let idx = attachmentIndex else { return }
                            attachments[idx].useFullContext = newValue
                            // When switching to "Entire Document", cache the
                            // extracted text in the file object so ChatViewModel
                            // can inject it into the payload without an extra fetch.
                            if newValue, let content = extractedContent {
                                if attachments[idx].uploadedFileObject == nil {
                                    attachments[idx].uploadedFileObject = [:]
                                }
                                var fileObj = attachments[idx].uploadedFileObject ?? [:]
                                var dataDict = fileObj["data"] as? [String: Any] ?? [:]
                                dataDict["content"] = content
                                fileObj["data"] = dataDict
                                attachments[idx].uploadedFileObject = fileObj
                            }
                            Haptics.play(.light)
                        }
                    ))
                    .labelsHidden()
                    .tint(theme.brandPrimary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content Tab

    @ViewBuilder
    private var contentTab: some View {
        if isLoadingContent {
            VStack {
                Spacer()
                ProgressView("Loading content…")
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
        } else if let content = extractedContent, !content.isEmpty {
            ScrollView {
                Text(content)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        } else if let error = loadError {
            ContentUnavailableView(
                "Could Not Load Content",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .padding(.top, 40)
        } else {
            ContentUnavailableView(
                "No Content",
                systemImage: "doc.text",
                description: Text("No extracted content is available for this file.")
            )
            .padding(.top, 40)
        }
    }

    // MARK: - Preview Tab

    @ViewBuilder
    private var previewTab: some View {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        let effectiveData = attachment.data ?? downloadedFileData
        if isLoadingPreview {
            VStack {
                Spacer()
                ProgressView("Loading preview…")
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
        } else if ext == "pdf", let data = effectiveData, let pdfDoc = PDFDocument(data: data) {
            PDFKitView(document: pdfDoc)
        } else if let data = effectiveData, let text = String(data: data, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
            }
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text("A preview is not available for this file type.")
            )
            .padding(.top, 40)
        }
    }

    /// SF Symbol name based on file extension.
    private var fileIcon: String {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "csv", "log": return "doc.plaintext"
        case "json", "xml", "yaml", "yml": return "curlybraces"
        case "html", "htm": return "globe"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "mp3", "wav", "m4a", "aac": return "waveform"
        case "mp4", "mov", "avi": return "film"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        default: return "doc"
        }
    }
}

// MARK: - PDFKit View

/// UIViewRepresentable wrapper for PDFKit's PDFView.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}

