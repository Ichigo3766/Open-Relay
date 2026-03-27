import SwiftUI

/// Sheet for creating or editing a Function.
/// Mirrors ToolEditorView in structure; key differences:
///  - Has a type picker (filter, pipe, action)
///  - Content is Python code
///  - Has is_active and is_global toggles
///  - Name/ID/description + Manifest section
struct FunctionEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    // MARK: - Input

    var existingFunction: FunctionDetail?
    var onSave: ((FunctionDetail) -> Void)?

    // MARK: - Form State

    @State private var functionId = ""
    @State private var name = ""
    @State private var type = "filter"
    @State private var description = ""
    @State private var content = ""
    @State private var isActive = true
    @State private var isGlobal = false
    @State private var manifestTitle = ""
    @State private var manifestAuthor = ""
    @State private var manifestVersion = ""
    @State private var manifestLicense = ""
    @State private var manifestRequirements = ""

    // UI
    @State private var isSaving = false
    @State private var validationError: String?
    @State private var idManuallyEdited = false
    @State private var isContentExpanded = false
    @State private var isAutoSettingId = false
    @State private var showDiscardConfirm = false
    @State private var showManifestSection = false

    @FocusState private var focusedField: Field?
    private enum Field { case name, functionId, description, content }

    private var manager: FunctionsManager? { dependencies.functionsManager }
    private var isEditing: Bool { existingFunction != nil }

    private let typeOptions = ["filter", "pipe", "action"]

    private var hasChanges: Bool {
        guard let existing = existingFunction else {
            return !name.isEmpty || !functionId.isEmpty || !content.isEmpty
        }
        return name != existing.name
            || functionId != existing.id
            || description != existing.description
            || content != existing.content
            || type != existing.type
            || isActive != existing.isActive
            || isGlobal != existing.isGlobal
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    codeSection
                    settingsSection
                    manifestSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Function" : "New Function")
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
            .sheet(isPresented: $isContentExpanded) {
                FullscreenContentEditor(
                    title: "Python Code",
                    placeholder: "# Write your Python function code here…",
                    content: $content
                )
            }
        }
        .onAppear { populateFields() }
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Function Info")
            fieldCard {
                VStack(spacing: 0) {
                    // Name
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. OpenRouter Search", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                if !idManuallyEdited {
                                    isAutoSettingId = true
                                    functionId = generateId(from: newValue)
                                    isAutoSettingId = false
                                }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // ID
                    HStack {
                        Text("ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. openrouter_search", text: $functionId)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .functionId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: functionId) { _, _ in
                                if !isAutoSettingId { idManuallyEdited = true }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Type — read-only when editing, picker when creating
                    HStack {
                        Text("Type")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        if isEditing {
                            Text(type.capitalized)
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                        } else {
                            Picker("", selection: $type) {
                                ForEach(typeOptions, id: \.self) { opt in
                                    Text(opt.capitalized).tag(opt)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Description
                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("Short description", text: $description)
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

    // MARK: - Code Section

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Python Code")
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
            fieldCard {
                TextEditor(text: $content)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 220, maxHeight: 440)
                    .focused($focusedField, equals: .content)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
                    .fontDesign(.monospaced)
            }
        }
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                HStack {
                    Text("Active")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Toggle("", isOn: $isActive)
                        .tint(theme.brandPrimary)
                        .labelsHidden()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Manifest Section

    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showManifestSection.toggle()
                }
            } label: {
                HStack {
                    sectionHeader("Manifest (Optional)")
                    Spacer()
                    Image(systemName: showManifestSection ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if showManifestSection {
                fieldCard {
                    VStack(spacing: 0) {
                        manifestRow(label: "Title", placeholder: "Display title", text: $manifestTitle)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Author", placeholder: "Author name", text: $manifestAuthor)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Version", placeholder: "e.g. 1.0.0", text: $manifestVersion)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "License", placeholder: "e.g. MIT", text: $manifestLicense)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Requirements", placeholder: "pip packages, comma-separated", text: $manifestRequirements)
                    }
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
    }

    @ViewBuilder
    private func manifestRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            TextField(placeholder, text: text)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 12)
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
                          || functionId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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

    private func populateFields() {
        guard let fn = existingFunction else { return }
        name = fn.name
        functionId = fn.id
        type = fn.type
        description = fn.description
        content = fn.content
        isActive = fn.isActive
        isGlobal = fn.isGlobal
        manifestTitle = fn.manifest.title
        manifestAuthor = fn.manifest.author
        manifestVersion = fn.manifest.version
        manifestLicense = fn.manifest.license
        manifestRequirements = fn.manifest.requirements
        idManuallyEdited = true

        if !manifestTitle.isEmpty || !manifestAuthor.isEmpty || !manifestVersion.isEmpty {
            showManifestSection = true
        }
    }

    private func generateId(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedId = functionId.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name."
            isSaving = false
            return
        }
        guard !trimmedId.isEmpty else {
            validationError = "Please enter an ID."
            isSaving = false
            return
        }

        let manifest = ToolManifest(
            title: manifestTitle,
            author: manifestAuthor,
            version: manifestVersion,
            license: manifestLicense,
            requirements: manifestRequirements
        )

        do {
            if let existing = existingFunction {
                let detail = FunctionDetail(
                    id: trimmedId,
                    name: trimmedName,
                    type: type,
                    content: content,
                    description: description,
                    manifest: manifest,
                    isActive: isActive,
                    isGlobal: isGlobal,
                    userId: existing.userId,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                )
                let updated = try await manager.updateFunction(detail)
                onSave?(updated)
            } else {
                let detail = FunctionDetail(
                    id: trimmedId,
                    name: trimmedName,
                    type: type,
                    content: content,
                    description: description,
                    manifest: manifest,
                    isActive: isActive,
                    isGlobal: isGlobal
                )
                let created = try await manager.createFunction(from: detail)
                onSave?(created)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
        isSaving = false
    }
}
