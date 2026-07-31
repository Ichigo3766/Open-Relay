import SwiftUI

// MARK: - Admin External Knowledge View

/// Admin Settings → External Knowledge — manage external vector DB connections (Qdrant, Milvus, pgvector).
struct AdminExternalKnowledgeView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminExternalKnowledgeViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                if viewModel.isLoading {
                    loadingState
                } else {
                    sourcesSection
                }
                Spacer(minLength: 80)
            }
            .padding(.top, Spacing.md)
        }
        .background(theme.background)
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showEditor) {
            ExternalKnowledgeEditorSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading…").scaledFont(size: 16).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 100)
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "externaldrive.connected.to.line.below").scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.brandPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EXTERNAL KNOWLEDGE SOURCES").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary).tracking(0.8)
                        Text("EXPERIMENTAL").scaledFont(size: 9, weight: .heavy).foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(theme.textTertiary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                Spacer()
                Button {
                    viewModel.openCreate()
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 14, weight: .semibold).foregroundStyle(theme.brandPrimary)
                        .frame(width: 28, height: 28).background(theme.brandPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)

            if viewModel.items.isEmpty {
                SettingsSection(footer: "Test must pass before a source is created.") {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "externaldrive.badge.questionmark").scaledFont(size: 28).foregroundStyle(theme.textTertiary)
                        Text("No external knowledge sources configured.")
                            .scaledFont(size: 14).foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Spacing.lg)
                }
            } else {
                SettingsSection {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        sourceRow(item, isLast: index == viewModel.items.count - 1)
                    }
                }
            }

            if let err = viewModel.error {
                errorBanner(err)
            }
        }
    }

    private func sourceRow(_ item: ExternalKnowledgeItem, isLast: Bool) -> some View {
        let conn = viewModel.connectionForItem(item)
        let isEnabled = conn?.enabled != false
        return VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .scaledFont(size: 16).foregroundStyle(theme.textTertiary).frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(isEnabled ? theme.textPrimary : theme.textTertiary)
                    HStack(spacing: 4) {
                        Text(item.provider ?? conn?.provider ?? "").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                        if let sn = item.sourceName {
                            Text("· \(sn)").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .opacity(isEnabled ? 1 : 0.5)
                }

                Spacer()

                Button {
                    viewModel.openEdit(item: item)
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "gearshape").scaledFont(size: 15).foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(conn == nil)

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { _ in Task { await viewModel.toggleSource(item: item) } }
                ))
                .labelsHidden().tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.screenPadding).padding(.vertical, Spacing.sm)
            if !isLast { Divider().padding(.leading, Spacing.screenPadding) }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.circle.fill").scaledFont(size: 12).foregroundStyle(theme.error)
            Text(message).scaledFont(size: 12).foregroundStyle(theme.error).lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - External Knowledge Editor Sheet

struct ExternalKnowledgeEditorSheet: View {
    @Bindable var viewModel: AdminExternalKnowledgeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // Name + Provider
                Section {
                    HStack {
                        TextField("Research Knowledge", text: $viewModel.formName)
                            .onChange(of: viewModel.formName) { _, _ in viewModel.testResult = nil }
                        Picker("", selection: $viewModel.formProvider) {
                            Text("Qdrant").tag("qdrant")
                            Text("Milvus").tag("milvus")
                            Text("pgvector").tag("pgvector")
                        }
                        .labelsHidden()
                        .onChange(of: viewModel.formProvider) { _, _ in
                            viewModel.applyProviderDefaults()
                            viewModel.testResult = nil
                        }
                    }
                    TextField("Description (optional)", text: $viewModel.formDescription, axis: .vertical)
                        .lineLimit(1...3)
                } header: { Text("Source") }

                // Connection
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Endpoint").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField(endpointPlaceholder, text: $viewModel.formEndpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onChange(of: viewModel.formEndpoint) { _, _ in viewModel.testResult = nil }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Timeout (s)").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("30", text: $viewModel.formTimeout).keyboardType(.numberPad)
                        }
                        if viewModel.formProvider != "pgvector" {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Key / Token").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                HStack {
                                    if viewModel.showAPIKey {
                                        TextField("", text: $viewModel.formAPIKey)
                                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    } else {
                                        SecureField("", text: $viewModel.formAPIKey)
                                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    }
                                    Button { viewModel.showAPIKey.toggle() } label: {
                                        Image(systemName: viewModel.showAPIKey ? "eye.slash" : "eye")
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onChange(of: viewModel.formAPIKey) { _, _ in viewModel.testResult = nil }
                            }
                        }
                    }

                    if viewModel.formProvider == "milvus" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Database").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("Default", text: $viewModel.formDbName)
                                .onChange(of: viewModel.formDbName) { _, _ in viewModel.testResult = nil }
                        }
                    }
                } header: { Text("Connection") }

                // Schema
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Collection").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("research-docs", text: $viewModel.formSourceName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: viewModel.formSourceName) { _, _ in viewModel.testResult = nil }
                    }

                    if viewModel.formProvider == "pgvector" {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Table").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                TextField("document_chunk", text: $viewModel.formTableName)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Collection Field").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                TextField("collection_name", text: $viewModel.formCollectionField)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Content Field").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField(viewModel.formProvider == "pgvector" ? "text" : "payload.text", text: $viewModel.formContentField)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onChange(of: viewModel.formContentField) { _, _ in viewModel.testResult = nil }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Vector Field").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField(viewModel.formProvider == "qdrant" ? "Default" : "vector", text: $viewModel.formVectorField)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onChange(of: viewModel.formVectorField) { _, _ in viewModel.testResult = nil }
                        }
                    }
                } header: { Text("Schema") }

                // Test
                Section {
                    HStack {
                        TextField("Ask a test question", text: $viewModel.formTestQuery)
                            .onChange(of: viewModel.formTestQuery) { _, _ in viewModel.testResult = nil }
                        if viewModel.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Test") { Task { await viewModel.testSource() } }
                                .fontWeight(.semibold)
                                .disabled(viewModel.formEndpoint.isEmpty || viewModel.formSourceName.isEmpty || viewModel.formTestQuery.isEmpty)
                        }
                    }
                    if viewModel.testPassed {
                        Label("Test passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if viewModel.testResult != nil && !viewModel.testPassed {
                        Label("Test returned no results", systemImage: "xmark.circle.fill").foregroundStyle(theme.error)
                    }
                } header: {
                    Text("Test Query")
                } footer: {
                    Text("External vectors must be generated with the same embedding model configured in Open WebUI.")
                }
            }
            .navigationTitle(viewModel.editingItemId != nil ? "Edit Connection" : "Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showEditor = false; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(viewModel.editingItemId != nil ? "Save" : "Create") {
                            Task { await viewModel.saveSource(); dismiss() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!viewModel.formIsValid || !viewModel.testPassed)
                    }
                }
            }
        }
    }

    private var endpointPlaceholder: String {
        switch viewModel.formProvider {
        case "pgvector": return "postgresql://user:password@host:5432/db"
        case "milvus": return "http://milvus.example.com:19530"
        default: return "https://qdrant.example.com"
        }
    }
}
