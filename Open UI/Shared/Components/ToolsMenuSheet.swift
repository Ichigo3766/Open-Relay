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

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        isEnabled: Bool = false,
        hasUserValves: Bool = false,
        isFunctionTool: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.hasUserValves = hasUserValves
        self.isFunctionTool = isFunctionTool
    }
}

// MARK: - Attach Destination (for inline nav)

private enum AttachDestination: Hashable {
    case files
    case notes
    case knowledge
    case referenceChats
    case skills
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

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var toolsExpanded = true
    @State private var navPath = NavigationPath()
    @State private var selectedDetent: PresentationDetent = .medium

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

    var body: some View {
        NavigationStack(path: $navPath) {
            mainContent
                .navigationDestination(for: AttachDestination.self) { destination in
                    destinationView(for: destination)
                }
        }
        .geometryGroup()
        .background(theme.background)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(CornerRadius.modal)
        .onChange(of: navPath.isEmpty) { _, isEmpty in
            if isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedDetent = .medium
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Drag handle
            sheetHandle
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Attachment actions row
                    attachmentActionsRow
                        .padding(.horizontal, Spacing.md)

                    // Attach rows (Files, Notes, Knowledge, Reference Chats, Skills)
                    attachChevronRows
                        .padding(.horizontal, Spacing.md)

                    // Built-in Tools section (web search, image gen, code interpreter)
                    let hasBuiltins = isWebSearchAvailable || isImageGenerationAvailable || isCodeInterpreterAvailable
                    if hasBuiltins {
                        builtinToolsSection
                            .padding(.horizontal, Spacing.md)
                    }

                    // Tools section
                    toolsSection
                        .padding(.horizontal, Spacing.md)
                }
                .padding(.bottom, Spacing.lg)
            }
        }
        .background(theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Destination Views

    @ViewBuilder
    private func destinationView(for destination: AttachDestination) -> some View {
        switch destination {
        case .files:
            InlineFilesPickerView(
                apiClient: apiClient,
                onFilesSelected: { attachments in
                    onFilesSelected?(attachments)
                    dismiss()
                }
            )
        case .notes:
            InlineNotesPickerView(
                notesManager: notesManager,
                onNoteSelected: { note in
                    if !selectedNotes.contains(where: { $0.id == note.id }) {
                        selectedNotes.append(note)
                    }
                    dismiss()
                }
            )
        case .knowledge:
            InlineKnowledgePickerView(
                apiClient: apiClient,
                onItemSelected: { item in
                    if !selectedKnowledgeItems.contains(where: { $0.id == item.id }) {
                        selectedKnowledgeItems.append(item)
                    }
                    dismiss()
                }
            )
        case .referenceChats:
            InlineReferenceChatPickerView(
                conversationManager: conversationManager,
                onSelect: { chat in
                    selectedReferenceChats.append(chat)
                    dismiss()
                }
            )
        case .skills:
            InlineSkillsPickerView(
                skills: skills,
                selectedSkillIds: $selectedSkillIds,
                isLoadingSkills: isLoadingSkills,
                onDone: { dismiss() }
            )
        }
    }

    // MARK: - Sheet Handle

    private var sheetHandle: some View {
        Capsule()
            .fill(theme.textTertiary.opacity(0.4))
            .frame(width: 36, height: 5)
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

            attachmentActionButton(
                icon: "camera",
                label: String(localized: "Camera"),
                action: onCameraCapture
            )
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
            // Dismiss the tools sheet first, then trigger the action
            // after a small delay to avoid sheet presentation conflicts.
            dismiss()
            if let action {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    action()
                }
            }
        } label: {
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
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : OpacityLevel.disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Attach Chevron Rows

    private var attachChevronRows: some View {
        VStack(spacing: Spacing.xs) {
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
            selectedDetent = .large
            navPath.append(destination)
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
        .buttonStyle(.plain)
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
            withAnimation(MicroAnimation.snappy) {
                isOn.wrappedValue.toggle()
            }
            Haptics.play(.light)
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
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
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

                    Image(systemName: toolsExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if toolsExpanded {
                if isLoadingTools {
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
        let isSelected = selectedToolIds.contains(tool.id)

        return HStack(spacing: 0) {
            // Main toggle area
            Button {
                withAnimation(MicroAnimation.snappy) {
                    if isSelected {
                        selectedToolIds.remove(tool.id)
                    } else {
                        selectedToolIds.insert(tool.id)
                    }
                }
                Haptics.play(.light)
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
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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

                    togglePill(isOn: isSelected)
                }
                .padding(Spacing.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tool.name)
            .accessibilityValue(isSelected ? "Enabled" : "Disabled")
            .accessibilityAddTraits(.isToggle)
        }
        .background(tileBackground(isOn: isSelected))
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

/// Custom nav bar used by all inline pickers — completely avoids
/// the UIKit nav bar safe-area settling that causes the 1-frame flicker.
private struct PickerNavBar: View {
    let title: String
    var trailingLabel: String? = nil
    var trailingDisabled: Bool = false
    var onTrailingTap: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            // Back button
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 16, weight: .semibold)
                    Text("Back")
                        .scaledFont(size: 17, weight: .regular)
                }
                .foregroundStyle(theme.brandPrimary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 80, alignment: .leading)

            Spacer()

            Text(title)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer()

            // Trailing action (e.g. "Attach (2)") — invisible placeholder when absent
            Group {
                if let label = trailingLabel, let action = onTrailingTap {
                    Button(label) { action() }
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .disabled(trailingDisabled)
                        .opacity(trailingDisabled ? 0.4 : 1)
                } else {
                    Text("").scaledFont(size: 17, weight: .semibold)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 12)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

// MARK: - Inline Picker Views (pushed inside NavigationStack)

// MARK: Files

struct InlineFilesPickerView: View {
    var apiClient: APIClient?
    var onFilesSelected: ([ChatAttachment]) -> Void

    @Environment(\.theme) private var theme

    @State private var files: [FileInfoResponse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedIds: Set<String> = []

    private var filtered: [FileInfoResponse] {
        guard !searchText.isEmpty else { return files }
        let q = searchText.lowercased()
        return files.filter { fileName($0).lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(
                title: "Attach Files",
                trailingLabel: selectedIds.isEmpty ? "Attach" : "Attach (\(selectedIds.count))",
                trailingDisabled: selectedIds.isEmpty,
                onTrailingTap: confirmSelection
            )

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                TextField("Search files…", text: $searchText)
                    .scaledFont(size: 15)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            Group {
                if isLoading {
                    ProgressView("Loading files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textSecondary)
                        Text(errorMessage)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") { Task { await loadFiles() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "doc")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text(searchText.isEmpty ? "No files uploaded yet" : "No files match \"\(searchText)\"")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.id) { file in
                        fileRow(file)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            Task { await loadFiles() }
        }
    }

    private func fileRow(_ file: FileInfoResponse) -> some View {
        let isSelected = selectedIds.contains(file.id)
        let name = fileName(file)
        let ct: String? = file.contentType
        return Button {
            if isSelected { selectedIds.remove(file.id) }
            else { selectedIds.insert(file.id) }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: fileIcon(for: ct))
                    .scaledFont(size: 18)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)

                    if let ct, !ct.isEmpty {
                        Text(ct)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? theme.brandPrimary.opacity(0.08) : Color.clear)
    }

    private func loadFiles() async {
        guard let apiClient else { errorMessage = "No server connection"; return }
        isLoading = true
        errorMessage = nil
        do {
            files = try await apiClient.getUserFiles()
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func confirmSelection() {
        let selected = files.filter { selectedIds.contains($0.id) }
        let attachments: [ChatAttachment] = selected.map { file in
            let name = fileName(file)
            var attachment = ChatAttachment(type: .file, name: name)
            attachment.uploadStatus = .completed
            attachment.uploadedFileId = file.id
            let ct = file.contentType ?? "application/octet-stream"
            attachment.uploadedFileObject = [
                "id": file.id,
                "filename": file.filename ?? name,
                "meta": ["name": name, "content_type": ct, "size": file.size ?? 0]
            ]
            return attachment
        }
        onFilesSelected(attachments)
    }

    private func fileName(_ file: FileInfoResponse) -> String { file.filename ?? file.id }

    private func fileIcon(for contentType: String?) -> String {
        guard let ct = contentType?.lowercased() else { return "doc" }
        if ct.hasPrefix("image/") { return "photo" }
        if ct.hasPrefix("video/") { return "video" }
        if ct.hasPrefix("audio/") { return "waveform" }
        if ct.contains("pdf") { return "doc.richtext" }
        if ct.contains("word") || ct.contains("document") { return "doc.text" }
        if ct.contains("spreadsheet") || ct.contains("excel") { return "tablecells" }
        if ct.contains("presentation") || ct.contains("powerpoint") { return "rectangle.on.rectangle" }
        if ct.contains("json") || ct.contains("xml") || ct.contains("html") { return "curlybraces" }
        if ct.contains("zip") || ct.contains("tar") || ct.contains("gzip") { return "archivebox" }
        if ct.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }
}

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

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                TextField("Search notes…", text: $searchText)
                    .scaledFont(size: 15)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5))
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

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
                            .listRowBackground(theme.cardBackground)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.4))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
        .buttonStyle(.plain)
    }

    private func loadNotes() async {
        guard let manager = notesManager else { return }
        isLoading = true
        notes = await manager.fetchNotes()
        isLoading = false
    }
}

// MARK: Knowledge

struct InlineKnowledgePickerView: View {
    var apiClient: APIClient?
    var onItemSelected: (KnowledgeItem) -> Void

    @Environment(\.theme) private var theme
    @State private var items: [KnowledgeItem] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filtered: [KnowledgeItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter { $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(title: "Attach Knowledge")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                TextField("Search knowledge…", text: $searchText)
                    .scaledFont(size: 15)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5))
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            Group {
                if isLoading {
                    ProgressView("Loading knowledge…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "cylinder.split.1x2")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text(searchText.isEmpty ? "No knowledge bases yet" : "No results for \"\(searchText)\"")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.id) { item in
                        knowledgeRow(item)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Task { await loadItems() } }
    }

    private func knowledgeRow(_ item: KnowledgeItem) -> some View {
        Button {
            onItemSelected(item)
        } label: {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [theme.brandPrimary.opacity(0.18), theme.brandPrimary.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "cylinder.split.1x2")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
            }
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    private func loadItems() async {
        guard let apiClient else { return }
        isLoading = true
        items = (try? await apiClient.getKnowledgeItems()) ?? []
        isLoading = false
    }
}

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
            theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                PickerNavBar(title: "Reference Chats")
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().foregroundStyle(theme.cardBorder.opacity(0.4))
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
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Task { await loadChats(page: 1, reset: true) } }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            TextField("Search chats…", text: $searchQuery)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5))
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
        .buttonStyle(.plain)
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
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
                    .scaledFont(size: 22)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
            }
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.plain)
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
