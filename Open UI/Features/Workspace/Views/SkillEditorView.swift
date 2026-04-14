import SwiftUI

/// Sheet for creating or editing a Skill.
/// Mirrors PromptEditorView/KnowledgeEditorView in structure and access grant UI.
struct SkillEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    // MARK: - Input

    var existingSkill: SkillDetail?
    var onSave: ((SkillDetail) -> Void)?

    // MARK: - Import Prefill Init

    /// Creates a new-skill editor pre-populated from imported data (e.g. Markdown / JSON import).
    /// Sets `slugManuallyEdited = true` so slug isn't overwritten when name is populated.
    init(
        prefillName: String = "",
        prefillSlug: String = "",
        prefillDescription: String = "",
        prefillContent: String = "",
        onSave: ((SkillDetail) -> Void)? = nil
    ) {
        self.existingSkill = nil
        self.onSave = onSave
        _name = State(initialValue: prefillName)
        _slug = State(initialValue: prefillSlug)
        _description = State(initialValue: prefillDescription)
        _content = State(initialValue: prefillContent)
        // Prevent slug from being auto-overwritten after pre-fill
        _slugManuallyEdited = State(initialValue: !prefillSlug.isEmpty)
    }

    /// Default init — used for edit mode and plain new-skill creation.
    init(existingSkill: SkillDetail? = nil, onSave: ((SkillDetail) -> Void)? = nil) {
        self.existingSkill = existingSkill
        self.onSave = onSave
    }

    // MARK: - Form State

    @State private var name = ""
    @State private var slug = ""        // auto-generated from name; editable
    @State private var description = ""
    @State private var content = ""
    @State private var isActive = true

    // Access control — matches PromptEditorView / KnowledgeEditorView pattern exactly
    /// isPrivate: true = Private (restricted to access list), false = Public (everyone)
    @State private var isPrivate: Bool = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var resolvedGroups: [String: GroupResponse] = [:]
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // UI
    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var slugManuallyEdited = false
    @State private var isContentExpanded = false
    @State private var isAutoSettingSlug = false   // guard: prevents slug onChange from firing when programmatically setting slug
    @State private var showDiscardConfirm = false
    @State private var initialIsActive = true
    @State private var isTogglingActive = false

    @FocusState private var focusedField: Field?
    private enum Field { case name, slug, description, content }

    private var manager: SkillsManager? { dependencies.skillsManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingSkill != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    private var hasChanges: Bool {
        guard let existing = existingSkill else {
            return !name.isEmpty || !slug.isEmpty || !content.isEmpty
        }
        let grantIds = Set(localAccessGrants.compactMap { $0.userId })
        let existingIds = Set(existing.accessGrants.compactMap { $0.userId })
        return name != existing.name
            || slug != existing.slug
            || description != existing.description
            || content != existing.content
            || isActive != existing.isActive
            || grantIds != existingIds
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    contentSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Skill" : "New Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            .alert("Validation Error", isPresented: .init(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "")
            }
            .alert("Access Error", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accessUpdateError ?? "")
            }
        }
        .onAppear {
            populateIfEditing()
            Task {
                await manager?.fetchAllUsers()
                await resolveGroupNames()
            }
        }
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Skill Info")
            fieldCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("e.g. Code Review Expert", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                if !slugManuallyEdited {
                                    isAutoSettingSlug = true
                                    slug = generateSlug(from: newValue)
                                }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("e.g. code-review-expert", text: $slug)
                            .scaledFont(size: 15)
                            .foregroundStyle(isEditing ? theme.textSecondary : theme.textPrimary)
                            .focused($focusedField, equals: .slug)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .disabled(isEditing)
                            .onChange(of: slug) { _, _ in
                                if isAutoSettingSlug {
                                    isAutoSettingSlug = false
                                } else {
                                    slugManuallyEdited = true
                                }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("Optional short description", text: $description)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, Spacing.md)
            }
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Instructions (Markdown)")
                Spacer()
                Button {
                    Haptics.play(.light)
                    isContentExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(6)
                        .background(theme.surfaceContainer.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("Write the instruction set in Markdown. Use headings, lists, and code blocks to structure the skill.")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)
            fieldCard {
                TextEditor(text: $content)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 200, maxHeight: 400)
                    .focused($focusedField, equals: .content)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
        }
        .sheet(isPresented: $isContentExpanded) {
            FullscreenContentEditor(
                title: "Instructions",
                placeholder: "Write Markdown instructions here…",
                content: $content
            )
        }
    }

    // MARK: - Settings Section (Active + Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                VStack(spacing: 0) {
                    // Active toggle
                    Toggle(isOn: $isActive) {
                        HStack(spacing: Spacing.sm) {
                            if isTogglingActive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Inactive skills won't appear in the chat picker.")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .tint(theme.brandPrimary)
                    .disabled(isTogglingActive)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .onChange(of: isActive) { oldVal, newVal in
                        guard isEditing, newVal != initialIsActive else { return }
                        initialIsActive = newVal
                        Task { await persistActiveToggle(id: existingSkill?.id) }
                    }

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Access Control
                    accessControlSection
                }
            }
        }
    }

    // MARK: - Access Control Section

    @ViewBuilder
    private var accessControlSection: some View {
        AccessControlSection(
            localAccessGrants: $localAccessGrants,
            isPrivate: $isPrivate,
            allUsers: allUsers,
            resolvedGroups: resolvedGroups,
            isUpdating: isUpdatingAccess,
            serverBaseURL: serverBaseURL,
            authToken: authToken,
            apiClient: dependencies.apiClient,
            onAccessModeChange: { newVal in
                await handleAccessModeChange(isPrivate: newVal)
            },
            onTogglePermission: { principalId, isGroup, currentlyWrite in
                await togglePermission(principalId: principalId, isGroup: isGroup, currentlyWrite: currentlyWrite)
            },
            onRemoveGrant: { principalId, isGroup in
                await removeGrant(principalId: principalId, isGroup: isGroup)
            },
            onAddGrants: { userIds, groupIds in
                await addGrants(userIds: userIds, groupIds: groupIds)
            }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .scaledFont(size: 16)
            .foregroundStyle(theme.textSecondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("Save") {
                    Task { await save() }
                }
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || slug.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Access Control Actions

    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existingSkill?.id, let manager else { return }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: localAccessGrants, isPublic: !isPrivate)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addGrants(userIds: [String], groupIds: [String]) async {
        guard let id = existingSkill?.id, let manager else {
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
                }
            }
            for groupId in groupIds {
                if !localAccessGrants.contains(where: { $0.groupId == groupId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false))
                }
            }
            Haptics.notify(.success)
            return
        }
        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        }
        for groupId in groupIds {
            if !newGrants.contains(where: { $0.groupId == groupId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: newGrants)
            localAccessGrants = updated
            await resolveGroupNames()
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func togglePermission(principalId: String, isGroup: Bool, currentlyWrite: Bool) async {
        let idx: Array<AccessGrant>.Index?
        if isGroup {
            idx = localAccessGrants.firstIndex(where: { $0.groupId == principalId })
        } else {
            idx = localAccessGrants.firstIndex(where: { $0.userId == principalId })
        }
        guard let idx else { return }
        let old = localAccessGrants[idx]
        let newGrant = AccessGrant(id: old.id, userId: old.userId, groupId: old.groupId, read: true, write: !currentlyWrite)
        var newGrants = localAccessGrants
        newGrants[idx] = newGrant

        guard let id = existingSkill?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeGrant(principalId: String, isGroup: Bool) async {
        guard let id = existingSkill?.id, let manager else {
            if isGroup {
                localAccessGrants.removeAll { $0.groupId == principalId }
            } else {
                localAccessGrants.removeAll { $0.userId == principalId }
            }
            Haptics.play(.light)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            if isGroup {
                localAccessGrants.removeAll { $0.groupId == principalId }
            } else {
                localAccessGrants.removeAll { $0.userId == principalId }
            }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: localAccessGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            if let detail = try? await manager.getDetail(id: id) {
                localAccessGrants = detail.accessGrants.filter { $0.userId != "*" }
            }
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func resolveGroupNames() async {
        guard let api = dependencies.apiClient else { return }
        let groupIds = Set(localAccessGrants.compactMap(\.groupId))
        let unknownIds = groupIds.subtracting(resolvedGroups.keys)
        guard !unknownIds.isEmpty else { return }
        do {
            let groups = try await api.getGroups()
            for g in groups where unknownIds.contains(g.id) {
                resolvedGroups[g.id] = g
            }
        } catch {}
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }

    private func populateIfEditing() {
        guard let skill = existingSkill else { return }
        name = skill.name
        slug = skill.slug
        description = skill.description
        content = skill.content
        isActive = skill.isActive
        initialIsActive = skill.isActive
        let hasWildcard = skill.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = skill.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
        slugManuallyEdited = true  // Don't auto-generate slug when editing
    }

    private func generateSlug(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// Calls the dedicated toggle endpoint immediately when the user flips the Active switch.
    private func persistActiveToggle(id: String?) async {
        guard let id, let manager else { return }
        isTogglingActive = true
        do {
            try await manager.toggleSkill(id: id)
            Haptics.play(.light)
        } catch {
            // Revert on failure
            isActive = !isActive
            initialIsActive = isActive
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isTogglingActive = false
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSlug = slug.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the skill."
            isSaving = false
            return
        }
        guard !trimmedSlug.isEmpty else {
            validationError = "Please enter an ID (slug) for the skill."
            isSaving = false
            return
        }

        // Build full access grants list including wildcard for public
        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        do {
            if let existing = existingSkill {
                // Update content/metadata first
                let detail = SkillDetail(
                    id: existing.id,
                    name: trimmedName,
                    slug: trimmedSlug,
                    description: description,
                    content: content,
                    isActive: isActive,
                    accessGrants: allGrants,
                    userId: existing.userId,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                )
                var updated = try await manager.updateSkill(detail)

                // Update access grants via dedicated endpoint
                let updatedGrants = try await manager.updateAccessGrants(
                    skillId: trimmedSlug,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants

                onSave?(updated)
            } else {
                let detail = SkillDetail(
                    name: trimmedName,
                    slug: trimmedSlug,
                    description: description,
                    content: content,
                    isActive: isActive,
                    accessGrants: allGrants
                )
                let created = try await manager.createSkill(from: detail)
                onSave?(created)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
        isSaving = false
    }
}
