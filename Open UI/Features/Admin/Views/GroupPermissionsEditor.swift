import SwiftUI

// MARK: - Group Permissions Editor

/// A scrollable editor for all group permission toggles, organized into sections.
/// Bound to a `Binding<GroupPermissions>` so it can be used for both
/// group-specific permissions and the default user permissions.
struct GroupPermissionsEditor: View {
    @Binding var permissions: GroupPermissions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.sectionGap) {
            workspaceSection
            sharingSection
            accessGrantsSection
            chatSection
            featuresSection
            settingsSection
        }
    }

    // MARK: - Workspace

    private var workspaceSection: some View {
        PermissionsSection(header: "Workspace") {
            permToggle("Models",          isOn: $permissions.workspace.models)
            permToggle("Knowledge",       isOn: $permissions.workspace.knowledge)
            permToggle("Prompts",         isOn: $permissions.workspace.prompts)
            permToggle("Tools",           isOn: $permissions.workspace.tools)
            permToggle("Skills",          isOn: $permissions.workspace.skills)
            permToggle("Import Models",   isOn: $permissions.workspace.modelsImport)
            permToggle("Export Models",   isOn: $permissions.workspace.modelsExport)
            permToggle("Import Prompts",  isOn: $permissions.workspace.promptsImport)
            permToggle("Export Prompts",  isOn: $permissions.workspace.promptsExport)
            permToggle("Import Tools",    isOn: $permissions.workspace.toolsImport)
            permToggle("Export Tools",    isOn: $permissions.workspace.toolsExport, isLast: true)
        }
    }

    // MARK: - Sharing

    private var sharingSection: some View {
        PermissionsSection(header: "Sharing") {
            permToggle("Models",           isOn: $permissions.sharing.models)
            permToggle("Public Models",    isOn: $permissions.sharing.publicModels)
            permToggle("Knowledge",        isOn: $permissions.sharing.knowledge)
            permToggle("Public Knowledge", isOn: $permissions.sharing.publicKnowledge)
            permToggle("Prompts",          isOn: $permissions.sharing.prompts)
            permToggle("Public Prompts",   isOn: $permissions.sharing.publicPrompts)
            permToggle("Tools",            isOn: $permissions.sharing.tools)
            permToggle("Public Tools",     isOn: $permissions.sharing.publicTools)
            permToggle("Skills",           isOn: $permissions.sharing.skills)
            permToggle("Public Skills",    isOn: $permissions.sharing.publicSkills)
            permToggle("Notes",            isOn: $permissions.sharing.notes)
            permToggle("Public Notes",     isOn: $permissions.sharing.publicNotes, isLast: true)
        }
    }

    // MARK: - Access Grants

    private var accessGrantsSection: some View {
        PermissionsSection(header: "Access Grants") {
            permToggle("Allow Users", isOn: $permissions.accessGrants.allowUsers, isLast: true)
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        PermissionsSection(header: "Chat") {
            permToggle("Controls",             isOn: $permissions.chat.controls)
            permToggle("Valves",               isOn: $permissions.chat.valves)
            permToggle("System Prompt",        isOn: $permissions.chat.systemPrompt)
            permToggle("Parameters",           isOn: $permissions.chat.params)
            permToggle("File Upload",          isOn: $permissions.chat.fileUpload)
            permToggle("Web Upload",           isOn: $permissions.chat.webUpload)
            permToggle("Delete Chat",          isOn: $permissions.chat.delete)
            permToggle("Delete Message",       isOn: $permissions.chat.deleteMessage)
            permToggle("Continue Response",    isOn: $permissions.chat.continueResponse)
            permToggle("Regenerate Response",  isOn: $permissions.chat.regenerateResponse)
            permToggle("Rate Response",        isOn: $permissions.chat.rateResponse)
            permToggle("Edit Message",         isOn: $permissions.chat.edit)
            permToggle("Share Chat",           isOn: $permissions.chat.share)
            permToggle("Export Chat",          isOn: $permissions.chat.export)
            permToggle("Speech-to-Text",       isOn: $permissions.chat.stt)
            permToggle("Text-to-Speech",       isOn: $permissions.chat.tts)
            permToggle("Voice Call",           isOn: $permissions.chat.call)
            permToggle("Multiple Models",      isOn: $permissions.chat.multipleModels)
            permToggle("Temporary Chat",       isOn: $permissions.chat.temporary)
            permToggle("Temporary Enforced",   isOn: $permissions.chat.temporaryEnforced, isLast: true)
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        PermissionsSection(header: "Features") {
            permToggle("API Keys",              isOn: $permissions.features.apiKeys)
            permToggle("Notes",                 isOn: $permissions.features.notes)
            permToggle("Channels",              isOn: $permissions.features.channels)
            permToggle("Folders",               isOn: $permissions.features.folders)
            permToggle("Direct Tool Servers",   isOn: $permissions.features.directToolServers)
            permToggle("Web Search",            isOn: $permissions.features.webSearch)
            permToggle("Image Generation",      isOn: $permissions.features.imageGeneration)
            permToggle("Code Interpreter",      isOn: $permissions.features.codeInterpreter)
            permToggle("Memories",              isOn: $permissions.features.memories)
            permToggle("Automations",           isOn: $permissions.features.automations, isLast: true)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        PermissionsSection(header: "Settings") {
            permToggle("Interface", isOn: $permissions.settings.interface, isLast: true)
        }
    }

    // MARK: - Helper

    private func permToggle(_ label: String, isOn: Binding<Bool>, isLast: Bool = false) -> some View {
        PermissionToggleRow(label: label, isOn: isOn, showDivider: !isLast)
    }
}

// MARK: - Permissions Section

private struct PermissionsSection<Content: View>: View {
    let header: String
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.sm)

            VStack(spacing: 0) {
                content()
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)
        }
    }
}

// MARK: - Permission Toggle Row

private struct PermissionToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var showDivider: Bool = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 11)

            if showDivider {
                Divider()
                    .padding(.horizontal, Spacing.md)
            }
        }
    }
}
