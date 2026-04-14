import SwiftUI

// MARK: - AdminConnectionsView

struct AdminConnectionsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminConnectionsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                if viewModel.isLoading {
                    loadingState
                } else {
                    openAISection
                    ollamaSection
                    directConnectionsSection
                    Spacer(minLength: 80)
                }
            }
            .padding(.top, Spacing.md)
        }
        .background(theme.background)
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadAll()
        }
        // Edit OpenAI Connection Sheet
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingOpenAIIndex != nil },
                set: { if !$0 { viewModel.editingOpenAIIndex = nil } }
            )
        ) {
            EditOpenAIConnectionSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Add OpenAI Connection Sheet
        .sheet(isPresented: $viewModel.isShowingAddOpenAI) {
            AddOpenAIConnectionSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Edit Ollama Connection Sheet
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingOllamaIndex != nil },
                set: { if !$0 { viewModel.editingOllamaIndex = nil } }
            )
        ) {
            EditOllamaConnectionSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Add Ollama Connection Sheet
        .sheet(isPresented: $viewModel.isShowingAddOllama) {
            AddOllamaConnectionSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading connections…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - OpenAI Section

    private var openAISection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with toggle
            HStack {
                Text("OpenAI API")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if viewModel.isSavingOpenAI {
                    ProgressView().controlSize(.small)
                        .frame(width: 44, height: 24)
                } else {
                    Toggle("", isOn: Binding(
                        get: { viewModel.openAIConfig.enableOpenAIAPI },
                        set: { _ in Task { await viewModel.toggleEnableOpenAIAPI() } }
                    ))
                    .labelsHidden()
                    .tint(theme.brandPrimary)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            if let err = viewModel.openAIError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // "Manage connections" sub-header + add button
            HStack {
                Text("Manage OpenAI API Connections")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button {
                    viewModel.beginAddOpenAIConnection()
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 32, height: 32)
                        .background(theme.brandPrimary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.sm)

            // Connection list
            VStack(spacing: 0) {
                let connections = viewModel.openAIConfig.orderedConnections
                if connections.isEmpty {
                    Text("No connections configured.")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.lg)
                        .padding(.horizontal, Spacing.screenPadding)
                } else {
                    ForEach(connections, id: \.index) { conn in
                        openAIConnectionRow(conn: conn)
                        if conn.index != connections.last?.index {
                            Divider()
                                .padding(.horizontal, Spacing.screenPadding)
                        }
                    }
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.sm)
        }
    }

    private func openAIConnectionRow(conn: (index: Int, url: String, key: String, config: OpenAIConnectionConfig)) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.url.isEmpty ? "(no URL)" : conn.url)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Gear icon (edit)
            Button {
                viewModel.beginEditOpenAIConnection(at: conn.index)
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per-connection enable toggle
            Toggle("", isOn: Binding(
                get: { conn.config.enable },
                set: { _ in Task { await viewModel.toggleOpenAIConnectionEnabled(at: conn.index) } }
            ))
            .labelsHidden()
            .tint(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await viewModel.deleteOpenAIConnection(at: conn.index) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Ollama Section

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ollama API")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if viewModel.isSavingOllama {
                    ProgressView().controlSize(.small)
                        .frame(width: 44, height: 24)
                } else {
                    Toggle("", isOn: Binding(
                        get: { viewModel.ollamaConfig.enableOllamaAPI },
                        set: { _ in Task { await viewModel.toggleEnableOllamaAPI() } }
                    ))
                    .labelsHidden()
                    .tint(theme.brandPrimary)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            if let err = viewModel.ollamaError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // Only show connections management when Ollama API is enabled
            if viewModel.ollamaConfig.enableOllamaAPI {
                // "Manage connections" sub-header + add button
                HStack {
                    Text("Manage Ollama API Connections")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Button {
                        viewModel.beginAddOllamaConnection()
                    } label: {
                        Image(systemName: "plus")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                            .background(theme.brandPrimary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.sm)

                // Connection list
                VStack(spacing: 0) {
                    let connections = viewModel.ollamaConfig.orderedConnections
                    if connections.isEmpty {
                        Text("No connections configured.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.lg)
                            .padding(.horizontal, Spacing.screenPadding)
                    } else {
                        ForEach(connections, id: \.index) { conn in
                            ollamaConnectionRow(conn: conn)
                            if conn.index != connections.last?.index {
                                Divider()
                                    .padding(.horizontal, Spacing.screenPadding)
                            }
                        }
                    }
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.sm)
            }
        }
    }

    private func ollamaConnectionRow(conn: (index: Int, url: String, config: OllamaConnectionConfig)) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(conn.url.isEmpty ? "(no URL)" : conn.url)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Gear icon (edit)
            Button {
                viewModel.beginEditOllamaConnection(at: conn.index)
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { conn.config.enable },
                set: { _ in Task { await viewModel.toggleOllamaConnectionEnabled(at: conn.index) } }
            ))
            .labelsHidden()
            .tint(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await viewModel.deleteOllamaConnection(at: conn.index) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Direct Connections Section

    private var directConnectionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            connectionSettingRow(
                title: "Direct Connections",
                description: "Direct Connections allow users to connect to their own OpenAI compatible API endpoints.",
                isOn: Binding(
                    get: { viewModel.connectionsConfig.enableDirectConnections },
                    set: { _ in Task { await viewModel.toggleDirectConnections() } }
                ),
                isSaving: viewModel.isSavingConnections
            )

            Divider()
                .padding(.horizontal, Spacing.screenPadding)

            connectionSettingRow(
                title: "Cache Base Model List",
                description: "Base Model List Cache speeds up access by fetching base models only at startup or on settings save—faster, but may not show recent base model changes.",
                isOn: Binding(
                    get: { viewModel.connectionsConfig.enableBaseModelsCache },
                    set: { _ in Task { await viewModel.toggleBaseModelsCache() } }
                ),
                isSaving: viewModel.isSavingConnections
            )

            if let err = viewModel.connectionsError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func connectionSettingRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        isSaving: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                Text(description)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
                    .frame(width: 44, height: 24)
            } else {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Helpers

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(theme.error)
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }
}

// MARK: - Shared Auth Picker Helper

private func authTypeNeedsKey(_ authType: String) -> Bool {
    authType != "none" && authType != "session" && authType != "oauth"
}

// MARK: - Edit OpenAI Connection Sheet

struct EditOpenAIConnectionSheet: View {
    @Bindable var viewModel: AdminConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Enable
                Section {
                    Toggle("Enable Connection", isOn: $viewModel.editOpenAIEnable)
                        .tint(theme.brandPrimary)
                }

                // MARK: Connection Type
                Section(header: Text("Connection Type")) {
                    Picker("Type", selection: $viewModel.editOpenAIConnectionType) {
                        Text("External").tag("external")
                        Text("Local").tag("local")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: URL
                Section(header: Text("API Base URL")) {
                    TextField("https://api.openai.com/v1", text: $viewModel.editOpenAIURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // MARK: Provider Type
                Section(header: Text("Provider")) {
                    Picker("Provider Type", selection: $viewModel.editOpenAIProviderType) {
                        Text("OpenAI").tag("")
                        Text("Azure OpenAI").tag("azure")
                    }

                    if viewModel.editOpenAIProviderType == "azure" {
                        TextField("API Version (e.g. 2024-02-01)", text: $viewModel.editOpenAIAPIVersion)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                // MARK: API Type
                Section(header: Text("API Type")) {
                    Picker("API Type", selection: $viewModel.editOpenAIAPIType) {
                        Text("Chat Completions").tag("chat_completions")
                        Text("Responses").tag("responses")
                    }
                }

                // MARK: Authentication
                Section(header: Text("Authentication")) {
                    Picker("Auth Type", selection: $viewModel.editOpenAIAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                        Text("OAuth").tag("oauth")
                    }

                    if authTypeNeedsKey(viewModel.editOpenAIAuthType) {
                        HStack {
                            Group {
                                if viewModel.editOpenAIShowKey {
                                    TextField("API Key", text: $viewModel.editOpenAIKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.editOpenAIKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                viewModel.editOpenAIShowKey.toggle()
                            } label: {
                                Image(systemName: viewModel.editOpenAIShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Headers
                Section(
                    header: Text("Additional Headers"),
                    footer: Text("Enter additional headers as JSON, e.g. {\"X-Custom\": \"value\"}")
                ) {
                    TextEditor(text: $viewModel.editOpenAIHeadersJSON)
                        .frame(minHeight: 80)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if viewModel.editOpenAIHeadersJSON.isEmpty {
                                Text("{}")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // MARK: Prefix ID
                Section(
                    header: Text("Prefix ID"),
                    footer: Text("Optional prefix prepended to model IDs from this connection.")
                ) {
                    TextField("e.g. my-server", text: $viewModel.editOpenAIPrefixId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // MARK: Model IDs
                Section(
                    header: Text("Model IDs"),
                    footer: viewModel.editOpenAIProviderType == "azure"
                        ? Text("Deployment names are required for Azure OpenAI.")
                        : nil
                ) {
                    ForEach(viewModel.editOpenAIModelIds, id: \.self) { modelId in
                        HStack {
                            Text(modelId)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeEditModelId(at: offsets)
                    }

                    HStack {
                        TextField("Add model ID…", text: $viewModel.editOpenAINewModelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addEditModelId() }
                        Button {
                            viewModel.addEditModelId()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.editOpenAINewModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Tags
                Section(header: Text("Tags")) {
                    ForEach(viewModel.editOpenAITags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeEditTag(at: offsets)
                    }

                    HStack {
                        TextField("Add tag…", text: $viewModel.editOpenAINewTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addEditTag() }
                        Button {
                            viewModel.addEditTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.editOpenAINewTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Delete
                Section {
                    Button(role: .destructive) {
                        viewModel.showDeleteOpenAIConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete Connection")
                                .scaledFont(size: 16, weight: .medium)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.editingOpenAIIndex = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingEditedOpenAI {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveOpenAIConnectionEdit()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.editOpenAIURL.isEmpty)
                    }
                }
            }
            .confirmationDialog(
                "Delete Connection",
                isPresented: $viewModel.showDeleteOpenAIConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let idx = viewModel.editingOpenAIIndex else { return }
                    viewModel.editingOpenAIIndex = nil
                    dismiss()
                    Task { await viewModel.deleteOpenAIConnection(at: idx) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This connection will be permanently removed.")
            }
        }
    }
}

// MARK: - Add OpenAI Connection Sheet

struct AddOpenAIConnectionSheet: View {
    @Bindable var viewModel: AdminConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Enable
                Section {
                    Toggle("Enable Connection", isOn: $viewModel.addOpenAIEnable)
                        .tint(theme.brandPrimary)
                }

                // MARK: Connection Type
                Section(header: Text("Connection Type")) {
                    Picker("Type", selection: $viewModel.addOpenAIConnectionType) {
                        Text("External").tag("external")
                        Text("Local").tag("local")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: URL
                Section(header: Text("API Base URL")) {
                    TextField("https://api.openai.com/v1", text: $viewModel.addOpenAIURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // MARK: Provider Type
                Section(header: Text("Provider")) {
                    Picker("Provider Type", selection: $viewModel.addOpenAIProviderType) {
                        Text("OpenAI").tag("")
                        Text("Azure OpenAI").tag("azure")
                    }

                    if viewModel.addOpenAIProviderType == "azure" {
                        TextField("API Version (e.g. 2024-02-01)", text: $viewModel.addOpenAIAPIVersion)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                // MARK: API Type
                Section(header: Text("API Type")) {
                    Picker("API Type", selection: $viewModel.addOpenAIAPIType) {
                        Text("Chat Completions").tag("chat_completions")
                        Text("Experimental Responses").tag("responses")
                    }
                }

                // MARK: Authentication
                Section(header: Text("Authentication")) {
                    Picker("Auth Type", selection: $viewModel.addOpenAIAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                        Text("OAuth").tag("oauth")
                    }

                    if authTypeNeedsKey(viewModel.addOpenAIAuthType) {
                        HStack {
                            Group {
                                if viewModel.addOpenAIShowKey {
                                    TextField("API Key", text: $viewModel.addOpenAIKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.addOpenAIKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                viewModel.addOpenAIShowKey.toggle()
                            } label: {
                                Image(systemName: viewModel.addOpenAIShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Headers
                Section(
                    header: Text("Additional Headers"),
                    footer: Text("Enter additional headers as JSON, e.g. {\"X-Custom\": \"value\"}")
                ) {
                    TextEditor(text: $viewModel.addOpenAIHeadersJSON)
                        .frame(minHeight: 80)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if viewModel.addOpenAIHeadersJSON.isEmpty {
                                Text("{}")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // MARK: Prefix ID
                Section(
                    header: Text("Prefix ID"),
                    footer: Text("Optional prefix prepended to model IDs from this connection.")
                ) {
                    TextField("e.g. my-server", text: $viewModel.addOpenAIPrefixId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // MARK: Model IDs
                Section(
                    header: Text("Model IDs"),
                    footer: viewModel.addOpenAIProviderType == "azure"
                        ? Text("Deployment names are required for Azure OpenAI.")
                        : nil
                ) {
                    ForEach(viewModel.addOpenAIModelIds, id: \.self) { modelId in
                        HStack {
                            Text(modelId)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeNewOpenAIModelId(at: offsets)
                    }

                    HStack {
                        TextField("Add model ID…", text: $viewModel.addOpenAINewModelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addNewOpenAIModelId() }
                        Button {
                            viewModel.addNewOpenAIModelId()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.addOpenAINewModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Tags
                Section(header: Text("Tags")) {
                    ForEach(viewModel.addOpenAITags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeNewOpenAITag(at: offsets)
                    }

                    HStack {
                        TextField("Add tag…", text: $viewModel.addOpenAINewTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addNewOpenAITag() }
                        Button {
                            viewModel.addNewOpenAITag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.addOpenAINewTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isShowingAddOpenAI = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingAddOpenAI {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") {
                            Task {
                                await viewModel.addOpenAIConnection()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.addOpenAIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Edit Ollama Connection Sheet

struct EditOllamaConnectionSheet: View {
    @Bindable var viewModel: AdminConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Enable
                Section {
                    Toggle("Enable Connection", isOn: $viewModel.editOllamaEnable)
                        .tint(theme.brandPrimary)
                }

                // MARK: Connection Type
                Section(header: Text("Connection Type")) {
                    Picker("Type", selection: $viewModel.editOllamaConnectionType) {
                        Text("External").tag("external")
                        Text("Local").tag("local")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: URL
                Section(header: Text("Base URL")) {
                    TextField("http://localhost:11434", text: $viewModel.editOllamaURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // MARK: Authentication
                Section(header: Text("Authentication")) {
                    Picker("Auth Type", selection: $viewModel.editOllamaAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                        Text("OAuth").tag("oauth")
                    }

                    if authTypeNeedsKey(viewModel.editOllamaAuthType) {
                        HStack {
                            Group {
                                if viewModel.editOllamaShowKey {
                                    TextField("API Key", text: $viewModel.editOllamaKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.editOllamaKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                viewModel.editOllamaShowKey.toggle()
                            } label: {
                                Image(systemName: viewModel.editOllamaShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Headers
                Section(
                    header: Text("Additional Headers"),
                    footer: Text("Enter additional headers as JSON, e.g. {\"X-Custom\": \"value\"}")
                ) {
                    TextEditor(text: $viewModel.editOllamaHeadersJSON)
                        .frame(minHeight: 80)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if viewModel.editOllamaHeadersJSON.isEmpty {
                                Text("{}")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // MARK: Prefix ID
                Section(
                    header: Text("Prefix ID"),
                    footer: Text("Optional prefix prepended to model IDs from this connection.")
                ) {
                    TextField("e.g. my-ollama", text: $viewModel.editOlamaPrefixId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // MARK: Model IDs
                Section(header: Text("Model IDs")) {
                    ForEach(viewModel.editOllamaModelIds, id: \.self) { modelId in
                        HStack {
                            Text(modelId)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeEditOllamaModelId(at: offsets)
                    }

                    HStack {
                        TextField("Add model ID…", text: $viewModel.editOllamaNewModelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addEditOllamaModelId() }
                        Button {
                            viewModel.addEditOllamaModelId()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.editOllamaNewModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Tags
                Section(header: Text("Tags")) {
                    ForEach(viewModel.editOlamaTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeEditOllamaTag(at: offsets)
                    }

                    HStack {
                        TextField("Add tag…", text: $viewModel.editOlamaNewTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addEditOllamaTag() }
                        Button {
                            viewModel.addEditOllamaTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.editOlamaNewTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Delete
                Section {
                    Button(role: .destructive) {
                        viewModel.showDeleteOllamaConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete Connection")
                                .scaledFont(size: 16, weight: .medium)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Edit Ollama Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.editingOllamaIndex = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingEditedOllama {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveOllamaConnectionEdit()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.editOllamaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .confirmationDialog(
                "Delete Connection",
                isPresented: $viewModel.showDeleteOllamaConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let idx = viewModel.editingOllamaIndex else { return }
                    viewModel.editingOllamaIndex = nil
                    dismiss()
                    Task { await viewModel.deleteOllamaConnection(at: idx) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This connection will be permanently removed.")
            }
        }
    }
}

// MARK: - Add Ollama Connection Sheet

struct AddOllamaConnectionSheet: View {
    @Bindable var viewModel: AdminConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Enable
                Section {
                    Toggle("Enable Connection", isOn: $viewModel.addOllamaEnable)
                        .tint(theme.brandPrimary)
                }

                // MARK: Connection Type
                Section(header: Text("Connection Type")) {
                    Picker("Type", selection: $viewModel.addOllamaConnectionType) {
                        Text("External").tag("external")
                        Text("Local").tag("local")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: URL
                Section(header: Text("Base URL")) {
                    TextField("http://localhost:11434", text: $viewModel.addOllamaURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // MARK: Authentication
                Section(header: Text("Authentication")) {
                    Picker("Auth Type", selection: $viewModel.addOllamaAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                        Text("OAuth").tag("oauth")
                    }

                    if authTypeNeedsKey(viewModel.addOllamaAuthType) {
                        HStack {
                            Group {
                                if viewModel.addOllamaShowKey {
                                    TextField("API Key", text: $viewModel.addOllamaKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.addOllamaKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                viewModel.addOllamaShowKey.toggle()
                            } label: {
                                Image(systemName: viewModel.addOllamaShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Headers
                Section(
                    header: Text("Additional Headers"),
                    footer: Text("Enter additional headers as JSON, e.g. {\"X-Custom\": \"value\"}")
                ) {
                    TextEditor(text: $viewModel.addOllamaHeadersJSON)
                        .frame(minHeight: 80)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if viewModel.addOllamaHeadersJSON.isEmpty {
                                Text("{}")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // MARK: Prefix ID
                Section(
                    header: Text("Prefix ID"),
                    footer: Text("Optional prefix prepended to model IDs from this connection.")
                ) {
                    TextField("e.g. my-ollama", text: $viewModel.addOlamaPrefixId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // MARK: Model IDs
                Section(header: Text("Model IDs")) {
                    ForEach(viewModel.addOllamaModelIds, id: \.self) { modelId in
                        HStack {
                            Text(modelId)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeNewOllamaModelId(at: offsets)
                    }

                    HStack {
                        TextField("Add model ID…", text: $viewModel.addOllamaNewModelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addNewOllamaModelId() }
                        Button {
                            viewModel.addNewOllamaModelId()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.addOllamaNewModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: Tags
                Section(header: Text("Tags")) {
                    ForEach(viewModel.addOlamaTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                                .scaledFont(size: 14)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        viewModel.removeNewOllamaTag(at: offsets)
                    }

                    HStack {
                        TextField("Add tag…", text: $viewModel.addOlamaNewTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { viewModel.addNewOllamaTag() }
                        Button {
                            viewModel.addNewOllamaTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(theme.brandPrimary)
                                .scaledFont(size: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.addOlamaNewTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Add Ollama Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isShowingAddOllama = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingAddOllama {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") {
                            Task {
                                await viewModel.addOllamaConnection()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.addOllamaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
