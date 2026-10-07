import SwiftUI

// MARK: - Tool Item Model

/// Represents a tool available in the overflow menu.
struct ToolItem: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String?
    var isEnabled: Bool
    /// True if the server reports this tool has user-configurable valves.
    var hasUserValves: Bool
    /// True if this item is a toggle-filter function (not a regular tool).
    var isFunctionTool: Bool
    var isAuthenticated: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        isEnabled: Bool = false,
        hasUserValves: Bool = false,
        isFunctionTool: Bool = false,
        isAuthenticated: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.hasUserValves = hasUserValves
        self.isFunctionTool = isFunctionTool
        self.isAuthenticated = isAuthenticated
    }
}

// MARK: - Attach Destination (for inline nav)

private enum AttachDestination: Hashable {
    case files
    case notes
    case knowledge
    case referenceChats
    case skills
    case toolPermissions
}

// MARK: - Tools Menu Sheet

/// A bottom sheet presenting attachment actions, feature toggles (web search),
/// and an expandable list of available tools.
struct ToolsMenuSheet: View {
    @Binding var webSearchEnabled: Bool
    @Binding var imageGenerationEnabled: Bool
    @Binding var codeInterpreterEnabled: Bool
    var isWebSearchAvailable: Bool = true
    var isImageGenerationAvailable: Bool = true
    var isCodeInterpreterAvailable: Bool = true
    var tools: [ToolItem]
    @Binding var selectedToolIds: Set<String>
    var isLoadingTools: Bool = false
    var onRefreshTools: (() async -> Void)? = nil
    var onFileAttachment: (() -> Void)?
    var onPhotoAttachment: (() -> Void)?
    var onCameraCapture: (() -> Void)?
    var onWebAttachment: (() -> Void)?

    // These are now handled inline via NavigationStack push
    var onFilesAttachment: (() -> Void)? = nil   // kept for API compat, unused if apiClient provided
    var onNotesAttachment: (() -> Void)? = nil
    var onKnowledgeAttachment: (() -> Void)? = nil
    var onReferenceChatAttachment: (() -> Void)? = nil

    // Data sources for inline pickers
    var apiClient: APIClient? = nil
    var notesManager: NotesManager? = nil
    var conversationManager: ConversationManager? = nil

    // Selection bindings for inline pickers
    @Binding var selectedNotes: [Note]
    @Binding var selectedKnowledgeItems: [KnowledgeItem]
    @Binding var selectedReferenceChats: [ReferenceChatItem]

    // Files picker callback (called when files are selected from inline picker)
    var onFilesSelected: (([ChatAttachment]) -> Void)? = nil

    /// Optional custom photo picker view (e.g. SwiftUI PhotosPicker).
    var photoPicker: AnyView?
    /// Called when the user taps the gear icon on a tool that has user valves.
    /// Receives (toolId, isFunctionTool).
    var onOpenToolUserValves: ((String, Bool) -> Void)?
    /// Whether the server has Notes feature enabled (config.features.enable_notes).
    /// When false, "Attach Notes" is hidden — mirrors WebUI's {#if $config?.features?.enable_notes}.
    var isNotesEnabled: Bool = true
    /// Skills available to toggle on/off for this conversation.
    var skills: [SkillItem] = []
    @Binding var selectedSkillIds: [String]
    var isLoadingSkills: Bool = false

    // MARK: - Tool Permissions (Human-in-the-Loop)
    /// Whether the server admin has enabled the Tool Permissions feature.
    /// When true a "Tool Permissions" row appears at the top of the sheet, mirroring
    /// `InputMenu.svelte` in the web UI.
    var isToolPermissionsEnabled: Bool = false
    /// Current tool approval mode: `"full"` (auto-run) or `"ask"` (require approval).
    var toolApprovalMode: String = "full"
    /// Called when the user picks a new mode in the Tool Permissions sub-page.
    var onToolApprovalModeChange: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var toolsExpanded = true
    @State private var page: AttachDestination? = nil
    @State private var connectingTool: ToolItem?

    // MARK: - Quick Pills (shared AppStorage key with ChatInputField)
    @AppStorage("quickPills") private var quickPillsData: String = ""

    private var savedQuickPillIds: Set<String> {
        Set(quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private func toggleQuickPill(_ id: String) {
        var ids = quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
        if ids.contains(id) {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        quickPillsData = ids.joined(separator: ",")
        Haptics.play(.light)
    }

    // MARK: - Morph Card Hooks
    //
    // The menu lives inside the composer card (see ChatInputField). The card owns
    // presentation; these hooks let the menu close it, open the camera page, and
    // report when a sub-page is showing so the card can grow taller.

    /// Shrinks the card back into the composer, then runs the given action (if any).
    var onCloseCard: (((() -> Void)?) -> Void)? = nil
    /// Opens the in-card camera. When nil, the Camera tile falls back to `onCameraCapture`.
    var onOpenCamera: (() -> Void)? = nil
    /// Called when a sub-page (Files, Notes, Knowledge…) is pushed or popped.
    var onExpandedChange: ((Bool) -> Void)? = nil

    private static let cardSpring: Animation = MorphCardMetrics.spring

    private func closeCard(then action: (() -> Void)? = nil) {
        if let onCloseCard {
            onCloseCard(action)
        } else {
            dismiss()
            action?()
        }
    }

    var body: some View {
        // In-card page switch (no NavigationStack): the main page slides out to the
        // left while the sub-page slides in from the right, and the card's height
        // follows on the same spring. Pages are transparent over the card's glass.
        ZStack {
            if let page {
                destinationView(for: page)
                    .environment(\.morphCardBack, MorphCardBackAction { showPage(nil) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(1)
            } else {
                mainContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .clipped()
        .geometryGroup()
        .background(Color.clear)
        .sheet(item: $connectingTool) { tool in
            if let apiClient {
                ToolConnectionView(tool: tool, apiClient: apiClient, onRefresh: onRefreshTools,
                    onConnected: { selectedToolIds.insert(tool.id) },
                    onDisable: { selectedToolIds.remove(tool.id) }).themed()
            }
        }
    }

    /// Switches the card's page (nil = main menu) and grows/shrinks the card with it.
    private func showPage(_ destination: AttachDestination?) {
        onExpandedChange?(destination != nil)
        withAnimation(Self.cardSpring) { page = destination }
    }

    // MARK: - Main Content

    /// When false, rows wait just under their final spot (faded out); flipping it to
    /// true deals them in one after another. The morph card sets it once it has grown.
    var contentRevealed: Bool = true

    private func revealRow(_ index: Int) -> some ViewModifier {
        MorphRowReveal(isRevealed: contentRevealed, index: index)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Attachment actions row
                    attachmentActionsRow
                        .padding(.horizontal, Spacing.md)
                        .modifier(revealRow(0))

                    // Attach rows (Files, Notes, Knowledge, Reference Chats, Skills)
                    attachChevronRows
                        .padding(.horizontal, Spacing.md)
                        .modifier(revealRow(1))

                    // Built-in Tools section (web search, image gen, code interpreter)
                    let hasBuiltins = isWebSearchAvailable || isImageGenerationAvailable || isCodeInterpreterAvailable
                    if hasBuiltins {
                        builtinToolsSection
                            .padding(.horizontal, Spacing.md)
                            .modifier(revealRow(2))
                    }

                    // Tools section
                    toolsSection
                        .padding(.horizontal, Spacing.md)
                        .modifier(revealRow(3))
                }
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.lg)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.clear)
    }

    // MARK: - Destination Views

    @ViewBuilder
    private func destinationView(for destination: AttachDestination) -> some View {
        switch destination {
        case .files:
            CardFilesPickerView(
                apiClient: apiClient,
                onFilesSelected: { attachments in
                    onFilesSelected?(attachments)
                    closeCard()
                }
            )
        case .notes:
            InlineNotesPickerView(
                notesManager: notesManager,
                onNoteSelected: { note in
                    if !selectedNotes.contains(where: { $0.id == note.id }) {
                        selectedNotes.append(note)
                    }
                    closeCard()
                }
            )
        case .knowledge:
            CardKnowledgePickerView(
                apiClient: apiClient,
                onItemSelected: { item in
                    if !selectedKnowledgeItems.contains(where: { $0.id == item.id && $0.type == item.type }) {
                        selectedKnowledgeItems.append(item)
                    }
                    closeCard()
                }
            )
        case .referenceChats:
            InlineReferenceChatPickerView(
                conversationManager: conversationManager,
                onSelect: { chat in
                    selectedReferenceChats.append(chat)
                    closeCard()
                }
            )
        case .skills:
            InlineSkillsPickerView(
                skills: skills,
                selectedSkillIds: $selectedSkillIds,
                isLoadingSkills: isLoadingSkills,
                onDone: { closeCard() }
            )
        case .toolPermissions:
            toolPermissionsPage
        }
    }

    // MARK: - Attachment Actions Row

    private var attachmentActionsRow: some View {
        HStack(spacing: Spacing.sm) {
            attachmentActionButton(
                icon: "doc",
                label: String(localized: "File"),
                action: onFileAttachment
            )

            // Use custom PhotosPicker if provided, otherwise fall back to callback
            if let photoPicker {
                photoPicker
            } else {
                attachmentActionButton(
                    icon: "photo",
                    label: String(localized: "Photo"),
                    action: onPhotoAttachment
                )
            }

            if let onOpenCamera {
                // Grows the card into the live viewfinder instead of closing it.
                Button {
                    Haptics.play(.light)
                    onOpenCamera()
                } label: {
                    attachmentActionLabel(icon: "camera", label: String(localized: "Camera"), isEnabled: true)
                }
                .buttonStyle(MorphPressStyle())
                .accessibilityLabel(String(localized: "Camera"))
            } else {
                attachmentActionButton(
                    icon: "camera",
                    label: String(localized: "Camera"),
                    action: onCameraCapture
                )
            }
            attachmentActionButton(
                icon: "globe",
                label: String(localized: "Webpage"),
                action: onWebAttachment
            )
        }
    }

    private func attachmentActionButton(
        icon: String,
        label: String,
        action: (() -> Void)?
    ) -> some View {
        let isEnabled = action != nil

        return Button {
            // Shrink the card back into the composer, then run the action.
            Haptics.play(.light)
            closeCard(then: action)
        } label: {
            attachmentActionLabel(icon: icon, label: label, isEnabled: isEnabled)
        }
        .buttonStyle(MorphPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : OpacityLevel.disabled)
        .accessibilityLabel(label)
    }

    private func attachmentActionLabel(icon: String, label: String, isEnabled: Bool) -> some View {
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.brandPrimary.opacity(isEnabled ? 0.2 : 0.08),
                                    theme.brandPrimary.opacity(isEnabled ? 0.12 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(
                            isEnabled
                                ? theme.brandPrimary
                                : theme.iconDisabled
                        )
                }

                Text(label)
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        isEnabled
                            ? theme.textPrimary
                            : theme.textDisabled
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(
                        theme.cardBorder.opacity(isEnabled ? 0.5 : 0.25),
                        lineWidth: 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    // MARK: - Attach Chevron Rows

    private var attachChevronRows: some View {
        VStack(spacing: Spacing.xs) {
            // Tool Permissions — shown at the top when the server admin has enabled it.
            // Mirrors InputMenu.svelte: shown above Upload Files when toolPermissionsEnabled.
            if isToolPermissionsEnabled {
                let modeLabel = toolApprovalMode == "ask" ? "Ask for approval" : "Full access"
                attachNavRow(
                    icon: "shield.lefthalf.filled",
                    title: "Tool Permissions",
                    subtitle: modeLabel,
                    destination: .toolPermissions,
                    isAvailable: true
                )
            }
            // Attach Files
            attachNavRow(
                icon: "doc.badge.plus",
                title: "Attach Files",
                subtitle: "Browse previously uploaded server files",
                destination: .files,
                isAvailable: apiClient != nil || onFilesAttachment != nil
            )
            // Attach Notes — only shown when server has notes feature enabled.
            // Mirrors WebUI: {#if $config?.features?.enable_notes ?? false}
            if isNotesEnabled {
                attachNavRow(
                    icon: "note.text",
                    title: "Attach Notes",
                    subtitle: "Inject a note's content into your message",
                    destination: .notes,
                    isAvailable: notesManager != nil || onNotesAttachment != nil
                )
            }
            // Attach Knowledge
            attachNavRow(
                icon: "cylinder.split.1x2",
                title: "Attach Knowledge",
                subtitle: "Add a knowledge base for retrieval",
                destination: .knowledge,
                isAvailable: apiClient != nil || onKnowledgeAttachment != nil
            )
            // Reference Chats
            attachNavRow(
                icon: "bubble.left.and.bubble.right",
                title: "Reference Chats",
                subtitle: "Include a previous conversation as context",
                destination: .referenceChats,
                isAvailable: conversationManager != nil || onReferenceChatAttachment != nil
            )
            // Attach Skills
            if !skills.isEmpty || isLoadingSkills {
                attachNavRow(
                    icon: "dollarsign.circle",
                    title: "Attach Skills",
                    subtitle: "Add agent skills to this conversation",
                    destination: .skills,
                    isAvailable: true
                )
            }
        }
    }

    /// A chevron row that pushes an `AttachDestination` onto the nav stack.
    private func attachNavRow(
        icon: String,
        title: String,
        subtitle: String,
        destination: AttachDestination,
        isAvailable: Bool
    ) -> some View {
        Button {
            Haptics.play(.light)
            showPage(destination)
        } label: {
            HStack(spacing: Spacing.sm) {
                toolGlyph(systemImage: icon, isSelected: false)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(Spacing.sm)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(MorphPressStyle(scale: 0.97))
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1.0 : OpacityLevel.disabled)
    }

    // MARK: - Feature Toggles

    private var webSearchToggle: some View {
        featureToggleTile(
            icon: "magnifyingglass",
            title: String(localized: "Web Search"),
            subtitle: String(localized: "Search the web and cite sources in replies"),
            isOn: $webSearchEnabled,
            pillId: "web"
        )
    }

    private var imageGenerationToggle: some View {
        featureToggleTile(
            icon: "photo.badge.plus",
            title: String(localized: "Image Generation"),
            subtitle: String(localized: "Generate images from text descriptions"),
            isOn: $imageGenerationEnabled,
            pillId: "image"
        )
    }

    private var codeInterpreterToggle: some View {
        featureToggleTile(
            icon: "chevron.left.forwardslash.chevron.right",
            title: String(localized: "Code Interpreter"),
            subtitle: String(localized: "Execute code and analyze data inline"),
            isOn: $codeInterpreterEnabled
        )
    }

    private func featureToggleTile(
        icon: String,
        title: String,
        subtitle: String?,
        isOn: Binding<Bool>,
        pillId: String? = nil
    ) -> some View {
        Button {
            // No global animation: only this tile's pill animates (via its own
            // `.animation(value:)`), so the chat behind doesn't re-animate.
            Haptics.play(.light)
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: Spacing.sm) {
                // Icon glyph
                toolGlyph(
                    systemImage: icon,
                    isSelected: isOn.wrappedValue
                )

                // Title and subtitle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .scaledFont(size: 14)
                        .fontWeight(isOn.wrappedValue ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Star / quick-pin button
                if let pillId {
                    let isPinned = savedQuickPillIds.contains(pillId)
                    Button {
                        toggleQuickPill(pillId)
                    } label: {
                        Image(systemName: isPinned ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(MicroAnimation.quick, value: isPinned)
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(isPinned ? theme.brandPrimary : theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPinned ? "Remove from quick actions" : "Add to quick actions")
                    .animation(MicroAnimation.snappy, value: isPinned)
                }

                // Toggle pill
                togglePill(isOn: isOn.wrappedValue)
            }
            .padding(Spacing.sm)
            .background(tileBackground(isOn: isOn.wrappedValue))
            .animation(MicroAnimation.snappy, value: isOn.wrappedValue)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        tileBorderColor(isOn: isOn.wrappedValue),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(MorphPressStyle(scale: 0.97))
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Tool Permissions Sub-Page

    /// The sub-page shown when the user taps "Tool Permissions" in the main sheet.
    /// Matches the web `InputMenu.svelte` `tab === 'tool_permissions'` panel.
    private var toolPermissionsPage: some View {
        VStack(spacing: 0) {
            PickerNavBar(title: "Tool Permissions")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Control whether tools run automatically or wait for your approval before each call.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.sm)

                // Option rows
                toolPermissionOptionRow(
                    value: "full",
                    label: "Full access",
                    description: "Run tools without asking for approval.",
                    icon: "bolt.fill"
                )
                .padding(.horizontal, Spacing.md)

                toolPermissionOptionRow(
                    value: "ask",
                    label: "Ask for approval",
                    description: "Stop before each tool call until you allow or deny it.",
                    icon: "hand.raised.fill"
                )
                .padding(.horizontal, Spacing.md)
            }

            Spacer()
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func toolPermissionOptionRow(
        value: String,
        label: String,
        description: String,
        icon: String
    ) -> some View {
        let isSelected = toolApprovalMode == value
        Button {
            Haptics.play(.light)
            onToolApprovalModeChange?(value)
            showPage(nil)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Icon glyph
                toolGlyph(systemImage: icon, isSelected: isSelected)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(label)
                        .scaledFont(size: 14, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(description)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                // Checkmark for the active option — matches web's SVG checkmark
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.accentColor)
                }
            }
            .padding(Spacing.sm)
            .background(
                isSelected
                    ? theme.accentColor.opacity(theme.isDark ? 0.12 : 0.08)
                    : theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accentColor.opacity(0.35)
                            : theme.cardBorder.opacity(0.55),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(MicroAnimation.snappy, value: isSelected)
    }

    // MARK: - Built-in Tools Section

    private var builtinToolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Built-in Tools")
                .scaledFont(size: 11, weight: .semibold)
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 2)

            if isWebSearchAvailable {
                webSearchToggle
            }

            if isImageGenerationAvailable {
                imageGenerationToggle
            }

            if isCodeInterpreterAvailable {
                codeInterpreterToggle
            }
        }
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Section header with expand/collapse
            Button {
                withAnimation(MicroAnimation.snappy) {
                    toolsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Tools")
                        .scaledFont(size: 14, weight: .medium)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textSecondary)

                    Spacer()

                    ExpandChevron(isExpanded: toolsExpanded, size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if toolsExpanded {
                // Only show the spinner when there's nothing to show yet; on refresh
                // keep the current list so the card doesn't re-layout mid-animation.
                if isLoadingTools && tools.isEmpty {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading tools…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(theme.cardBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
                    )
                } else if tools.isEmpty {
                    infoCard(message: "No tools available")
                } else {
                    ForEach(tools) { tool in
                        toolTile(tool: tool)
                    }
                }
            }
        }
    }

    private func toolTile(tool: ToolItem) -> some View {
        let isSelected = tool.isAuthenticated && selectedToolIds.contains(tool.id)

        return HStack(spacing: 0) {
            // Main toggle area
            Button {
                guard tool.isAuthenticated else { connectingTool = tool; return }
                Haptics.play(.light)
                if isSelected {
                    selectedToolIds.remove(tool.id)
                } else {
                    selectedToolIds.insert(tool.id)
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    toolGlyph(
                        systemImage: toolIcon(for: tool),
                        isSelected: isSelected
                    )

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(tool.name)
                            .scaledFont(size: 14)
                            .fontWeight(isSelected ? .semibold : .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if let desc = tool.description, !desc.isEmpty {
                            Text(desc)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    // Star / quick-pin button
                    let isPinned = savedQuickPillIds.contains(tool.id)
                    Button {
                        toggleQuickPill(tool.id)
                    } label: {
                        Image(systemName: isPinned ? "star.fill" : "star")
                            .scaledFont(size: 14, weight: .medium)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(MicroAnimation.quick, value: isPinned)
                            .foregroundStyle(isPinned ? theme.brandPrimary : theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPinned ? "Remove from quick actions" : "Add to quick actions")
                    .animation(MicroAnimation.snappy, value: isPinned)

                    // Gear icon — only shown when the tool has user-configurable valves
                    if tool.hasUserValves, let onOpenToolUserValves {
                        Button {
                            Haptics.play(.light)
                            closeCard {
                                onOpenToolUserValves(tool.id, tool.isFunctionTool)
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(theme.surfaceContainer.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Configure \(tool.name) valves")
                    }

                    if tool.isAuthenticated {
                        togglePill(isOn: isSelected)
                    } else {
                        Label("Connect", systemImage: "link").font(.caption)
                    }
                }
                .padding(Spacing.sm)
            }
            .buttonStyle(MorphPressStyle(scale: 0.97))
            .accessibilityLabel(tool.name)
            .accessibilityValue(tool.isAuthenticated ? (isSelected ? "Enabled" : "Disabled") : "Connection required")
            .accessibilityAddTraits(.isToggle)
        }
        .background(tileBackground(isOn: isSelected))
        .animation(MicroAnimation.snappy, value: isSelected)
        .clipShape(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .strokeBorder(
                    tileBorderColor(isOn: isSelected),
                    lineWidth: 0.5
                )
        )
        // Web parity (IntegrationsMenu): an MCP tool signed in through OAuth can be disconnected.
        .contextMenu {
            if tool.isAuthenticated, tool.id.hasPrefix("server:mcp:"), apiClient != nil {
                Button("Disconnect OAuth", systemImage: "link.badge.plus", role: .destructive) {
                    Task { await disconnectOAuth(tool) }
                }
            }
        }
    }

    /// DELETE /auths/oauth/sessions/mcp:{serverId}, then refresh tools so it shows "Connect" again.
    private func disconnectOAuth(_ tool: ToolItem) async {
        guard let apiClient else { return }
        let serverId = tool.id.split(separator: ":").last.map(String.init) ?? tool.id
        do {
            try await apiClient.deleteOAuthSession(provider: "mcp:\(serverId)")
            selectedToolIds.remove(tool.id)
            await onRefreshTools?()
            Haptics.notify(.success)
        } catch {
            Haptics.notify(.error)
        }
    }

    // MARK: - Shared Sub-Views

    private func toolGlyph(systemImage: String, isSelected: Bool) -> some View {
        let accentStart = theme.brandPrimary.opacity(
            isSelected ? 0.7 : 0.15
        )
        let accentEnd = theme.brandPrimary.opacity(
            isSelected ? 0.5 : 0.08
        )
        let iconColor = isSelected
            ? theme.brandOnPrimary
            : theme.iconPrimary.opacity(OpacityLevel.strong)

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accentStart, accentEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)

            Image(systemName: systemImage)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(iconColor)
        }
    }

    private func togglePill(isOn: Bool) -> some View {
        let trackColor = isOn
            ? theme.brandPrimary.opacity(0.9)
            : theme.cardBorder.opacity(0.5)
        let thumbColor = isOn
            ? theme.brandOnPrimary
            : theme.background.opacity(0.9)

        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .frame(width: 42, height: 22)

            Circle()
                .fill(thumbColor)
                .frame(width: 18, height: 18)
                .shadow(
                    color: theme.brandPrimary.opacity(0.25),
                    radius: 3,
                    y: 1
                )
                .padding(.horizontal, 2)
        }
        .animation(MicroAnimation.snappy, value: isOn)
    }

    private func tileBackground(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(theme.isDark ? 0.28 : 0.16)
            : theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12)
    }

    private func tileBorderColor(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(0.7)
            : theme.cardBorder.opacity(0.55)
    }

    private func infoCard(message: String) -> some View {
        Text(message)
            .scaledFont(size: 14)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(theme.cardBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
    }

    private func toolIcon(for tool: ToolItem) -> String {
        let name = tool.name.lowercased()
        if name.contains("image") || name.contains("vision") {
            return "photo"
        }
        if name.contains("code") || name.contains("python") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("calc") || name.contains("math") {
            return "function"
        }
        if name.contains("file") || name.contains("document") {
            return "doc"
        }
        if name.contains("api") || name.contains("request") {
            return "cloud"
        }
        if name.contains("search") {
            return "magnifyingglass"
        }
        return "square.grid.2x2"
    }
}

// MARK: - Shared Picker Nav Bar

/// Card-style header used by every Attach page inside the + card: a round ‹ back
/// button, centred title, and an optional capsule action (e.g. "Attach (2)").
struct PickerNavBar: View {
    let title: String
    var trailingLabel: String? = nil
    var trailingDisabled: Bool = false
    var onTrailingTap: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.morphCardBack) private var morphCardBack

    var body: some View {
        ZStack {
            Text(title)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)

            HStack(spacing: 0) {
                // Back — slides back to the card's main page when inside the
                // composer card, otherwise pops the presentation.
                Button {
                    Haptics.play(.light)
                    if let morphCardBack { morphCardBack() } else { dismiss() }
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(theme.surfaceContainer.opacity(theme.isDark ? 0.6 : 0.9)))
                        .contentShape(Circle())
                }
                .buttonStyle(MorphPressStyle())
                .accessibilityLabel("Back")

                Spacer()

                if let label = trailingLabel, let action = onTrailingTap {
                    Button {
                        Haptics.play(.light)
                        action()
                    } label: {
                        Text(label)
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.brandOnPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(theme.brandPrimary))
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(MorphPressStyle())
                    .disabled(trailingDisabled)
                    .opacity(trailingDisabled ? 0.4 : 1)
                    .animation(MicroAnimation.snappy, value: label)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }
}

/// Glass search field shared by the Attach pages inside the card.
struct CardSearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            TextField(prompt, text: $text)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5))
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Inline Picker Views (pushed inside NavigationStack)

// MARK: Files


// MARK: Notes

struct InlineNotesPickerView: View {
    var notesManager: NotesManager?
    var onNoteSelected: (Note) -> Void

    @Environment(\.theme) private var theme
    @State private var notes: [Note] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filteredNotes: [Note] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return notes }
        let q = searchText.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(q) ||
            $0.content.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(title: "Attach Note")

            CardSearchField(prompt: "Search notes…", text: $searchText)

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredNotes.isEmpty {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "note.text")
                            .scaledFont(size: 40, weight: .light)
                            .foregroundStyle(theme.textTertiary)
                        Text(searchText.isEmpty ? "No notes yet" : "No matching notes")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                        if searchText.isEmpty {
                            Text("Create notes to reference them in your chats")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, Spacing.xl)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredNotes) { note in
                        noteRow(note)
                            .listRowBackground(theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.4))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Color.clear)
        .onAppear { Task { await loadNotes() } }
    }

    private func noteRow(_ note: Note) -> some View {
        Button {
            onNoteSelected(note)
        } label: {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [theme.brandPrimary.opacity(0.18), theme.brandPrimary.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "note.text")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if !note.content.isEmpty {
                        Text(note.content)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                    if !note.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(note.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(theme.brandPrimary.opacity(0.1)))
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
            }
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(MorphPressStyle(scale: 0.97))
    }

    private func loadNotes() async {
        guard let manager = notesManager else { return }
        isLoading = true
        notes = await manager.fetchNotes()
        isLoading = false
    }
}

// MARK: Knowledge


// MARK: Reference Chats

struct InlineReferenceChatPickerView: View {
    let conversationManager: ConversationManager?
    let onSelect: (ReferenceChatItem) -> Void

    @Environment(\.theme) private var theme
    @State private var chats: [ReferenceChatItem] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil
    @State private var searchQuery = ""
    @State private var currentPage = 1
    @State private var hasMorePages = true
    @State private var isLoadingMore = false

    private var filteredChats: [ReferenceChatItem] {
        guard !searchQuery.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var groupedChats: [(title: String, items: [ReferenceChatItem])] {
        let order = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
        var grouped: [String: [ReferenceChatItem]] = [:]
        for chat in filteredChats { grouped[chat.timeRange, default: []].append(chat) }
        return order.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            return (title: key, items: items)
        }
    }

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                PickerNavBar(title: "Reference Chats")
                CardSearchField(prompt: "Search chats…", text: $searchQuery)
                if isLoading && chats.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.regular)
                        Text("Loading chats…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text(err)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            loadError = nil
                            Task { await loadChats(page: 1, reset: true) }
                        }
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredChats.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .scaledFont(size: 36)
                            .foregroundStyle(theme.textTertiary)
                        Text(searchQuery.isEmpty ? "No conversations found" : "No results for \"\(searchQuery)\"")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedChats, id: \.title) { group in
                            Section {
                                ForEach(group.items) { chat in
                                    chatRow(chat)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                                }
                            } header: {
                                Text(group.title)
                                    .scaledFont(size: 11, weight: .semibold)
                                    .textCase(.uppercase)
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.top, 8)
                            }
                        }
                        if hasMorePages && !isLoadingMore {
                            Color.clear.frame(height: 1)
                                .onAppear { Task { await loadMoreIfNeeded() } }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        if isLoadingMore {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                                .padding(.vertical, 8)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .onAppear { Task { await loadChats(page: 1, reset: true) } }
    }

    private func chatRow(_ chat: ReferenceChatItem) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(chat)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "bubble.left.and.bubble.right")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title.isEmpty ? "Untitled" : chat.title)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(chat.relativeTime)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.3), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(MorphPressStyle(scale: 0.97))
    }

    private func loadChats(page: Int, reset: Bool) async {
        guard !isLoading else { return }
        guard let manager = conversationManager else { loadError = "Not connected to a server."; return }
        if reset { isLoading = true }
        defer { isLoading = false }
        do {
            let conversations = try await manager.fetchConversationsPage(page: page)
            let newItems = conversations.compactMap { conv -> ReferenceChatItem? in
                guard !conv.isTemporary else { return nil }
                return ReferenceChatItem(id: conv.id, title: conv.title, updatedAt: conv.updatedAt, createdAt: conv.createdAt)
            }
            loadError = nil
            if reset { chats = newItems } else {
                let existingIds = Set(chats.map(\.id))
                chats.append(contentsOf: newItems.filter { !existingIds.contains($0.id) })
            }
            hasMorePages = !newItems.isEmpty
            currentPage = page
        } catch is CancellationError {
            if reset && chats.isEmpty { isLoading = false; Task { await loadChats(page: 1, reset: true) } }
        } catch { loadError = error.localizedDescription }
    }

    private func loadMoreIfNeeded() async {
        guard hasMorePages && !isLoadingMore && !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadChats(page: currentPage + 1, reset: false)
    }
}

// MARK: Skills (inline picker with toggles)

struct InlineSkillsPickerView: View {
    var skills: [SkillItem]
    @Binding var selectedSkillIds: [String]
    var isLoadingSkills: Bool
    var onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(title: "Attach Skills")

            Group {
                if isLoadingSkills {
                    VStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.regular)
                        Text("Loading skills…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if skills.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "dollarsign.circle")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text("No skills available")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(skills) { skill in
                        skillRow(skill)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Color.clear)
    }

    private func skillRow(_ skill: SkillItem) -> some View {
        let isSelected = selectedSkillIds.contains(skill.id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isSelected { selectedSkillIds.removeAll { $0 == skill.id } }
                else { selectedSkillIds.append(skill.id) }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [
                                theme.brandPrimary.opacity(isSelected ? 0.7 : 0.15),
                                theme.brandPrimary.opacity(isSelected ? 0.5 : 0.08)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "dollarsign.circle")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(isSelected ? theme.brandOnPrimary : theme.iconPrimary.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .scaledFont(size: 14, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .contentTransition(.symbolEffect(.replace))
                .animation(MicroAnimation.quick, value: isSelected)
                    .scaledFont(size: 22)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
            }
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(MorphPressStyle(scale: 0.97))
    }
}

// MARK: - Preview

#Preview("Tools Menu Sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ToolsMenuSheet(
                webSearchEnabled: .constant(false),
                imageGenerationEnabled: .constant(false),
                codeInterpreterEnabled: .constant(false),
                tools: [
                    ToolItem(name: "Web Search", description: "Search the web for fresh context."),
                    ToolItem(name: "Code Interpreter", description: "Execute code snippets inline."),
                ],
                selectedToolIds: .constant(["1"]),
                onFileAttachment: {},
                onPhotoAttachment: {},
                onCameraCapture: {},
                onWebAttachment: {},
                selectedNotes: .constant([]),
                selectedKnowledgeItems: .constant([]),
                selectedReferenceChats: .constant([]),
                selectedSkillIds: .constant([])
            )
        }
        .themed()
}
