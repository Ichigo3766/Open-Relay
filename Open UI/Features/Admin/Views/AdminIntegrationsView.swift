import SwiftUI

// MARK: - AdminIntegrationsView

struct AdminIntegrationsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminIntegrationsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                if viewModel.isLoading {
                    loadingState
                } else {
                    toolServersSection
                    terminalServersSection
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
        // Edit Tool Server Sheet
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingToolServerIndex != nil },
                set: { if !$0 { viewModel.editingToolServerIndex = nil } }
            )
        ) {
            EditToolServerSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Add Tool Server Sheet
        .sheet(isPresented: $viewModel.isShowingAddToolServer) {
            AddToolServerSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Edit Terminal Server Sheet
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingTerminalIndex != nil },
                set: { if !$0 { viewModel.editingTerminalIndex = nil } }
            )
        ) {
            EditTerminalSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Add Terminal Server Sheet
        .sheet(isPresented: $viewModel.isShowingAddTerminal) {
            AddTerminalSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading integrations…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Tool Servers Section

    private var toolServersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Manage Tool Servers")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button {
                    viewModel.beginAddToolServer()
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

            if let err = viewModel.toolServersError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // Connection list
            VStack(spacing: 0) {
                let connections = viewModel.toolServersConfig.TOOL_SERVER_CONNECTIONS
                if connections.isEmpty {
                    Text("No tool servers configured.")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.lg)
                } else {
                    ForEach(Array(connections.enumerated()), id: \.offset) { index, conn in
                        toolServerRow(index: index, conn: conn)
                        if index != connections.count - 1 {
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

            Text("Connect to your own OpenAPI compatible external tool servers.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.xs)
        }
    }

    private func toolServerRow(index: Int, conn: ToolServerConnection) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "wrench.and.screwdriver")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(conn.displayName)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if !conn.displayId.isEmpty && conn.displayId != conn.displayName {
                        Text(conn.displayId)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                if let type = conn.type {
                    Text(type.uppercased())
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            // Gear icon (edit)
            Button {
                viewModel.beginEditToolServer(at: index)
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Enable toggle
            if viewModel.isSavingToolServers {
                ProgressView().controlSize(.small)
                    .frame(width: 44, height: 24)
            } else {
                Toggle("", isOn: Binding(
                    get: { conn.config?.enable ?? true },
                    set: { _ in Task { await viewModel.toggleToolServerEnabled(at: index) } }
                ))
                .labelsHidden()
                .tint(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
    }

    // MARK: - Terminal Servers Section

    private var terminalServersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(alignment: .center) {
                Text("Open Terminal")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text("EXPERIMENTAL")
                    .scaledFont(size: 9, weight: .heavy)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.textTertiary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Spacer()

                Button {
                    viewModel.beginAddTerminal()
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

            if let err = viewModel.terminalServersError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // Connection list
            VStack(spacing: 0) {
                let connections = viewModel.terminalServersConfig.TERMINAL_SERVER_CONNECTIONS
                if connections.isEmpty {
                    Text("No terminal servers configured.")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.lg)
                } else {
                    ForEach(Array(connections.enumerated()), id: \.offset) { index, conn in
                        terminalRow(index: index, conn: conn)
                        if index != connections.count - 1 {
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

            Text("Connect to Open Terminal instances. All users will have access to file browsing and terminal tools through these servers.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.xs)
        }
    }

    private func terminalRow(index: Int, conn: TerminalServerConnection) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "cloud")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 24)

            Text(conn.displayName)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer()

            Button {
                viewModel.beginEditTerminal(at: index)
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if viewModel.isSavingTerminalServers {
                ProgressView().controlSize(.small)
                    .frame(width: 44, height: 24)
            } else {
                Toggle("", isOn: Binding(
                    get: { conn.enabled ?? true },
                    set: { _ in Task { await viewModel.toggleTerminalEnabled(at: index) } }
                ))
                .labelsHidden()
                .tint(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
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

// MARK: - Auth Helpers

/// Returns auth type picker items appropriate for the given tool type
private func authTypesForToolType(_ toolType: String) -> [(label: String, value: String)] {
    if toolType == "mcp" {
        return [
            ("None", "none"),
            ("Bearer", "bearer"),
            ("Session", "session"),
            ("OAuth", "oauth"),
            ("OAuth 2.1", "oauth2.1"),
            ("OAuth 2.1 (Static)", "oauth2.1_static"),
        ]
    } else {
        // OpenAPI
        return [
            ("None", "none"),
            ("Bearer", "bearer"),
            ("Session", "session"),
            ("OAuth", "oauth"),
        ]
    }
}

/// Whether the auth type needs an API key field
private func authTypeNeedsKey(_ authType: String) -> Bool {
    authType == "bearer"
}

/// Whether the auth type needs client ID/secret fields
private func authTypeNeedsClientCredentials(_ authType: String) -> Bool {
    authType == "oauth2.1_static"
}

// MARK: - Edit Tool Server Sheet

struct EditToolServerSheet: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var showAdvanced = false
    @State private var showAccessControl = false

    var body: some View {
        NavigationStack {
            Form {
                // Type
                Section(header: Text("Type")) {
                    Picker("Type", selection: $viewModel.editToolType) {
                        Text("OpenAPI").tag("openapi")
                        Text("MCP").tag("mcp")
                    }
                    .pickerStyle(.segmented)
                }

                // Name / ID
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Name").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("Enter name", text: $viewModel.editToolName)
                                .textInputAutocapitalization(.never)
                        }
                        VStack(alignment: .leading) {
                            Text("ID (optional)").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("auto", text: $viewModel.editToolId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Description").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("Enter description", text: $viewModel.editToolDescription)
                    }
                }

                // URL + Enable + Verify
                Section(header: Text("URL")) {
                    HStack {
                        TextField("API Base URL", text: $viewModel.editToolURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        if viewModel.isVerifyingToolServer {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await viewModel.verifyToolServer() }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("", isOn: $viewModel.editToolEnable)
                            .labelsHidden()
                            .tint(theme.brandPrimary)
                    }

                    if let result = viewModel.verifyToolServerResult {
                        Text(result)
                            .scaledFont(size: 12)
                            .foregroundStyle(result.hasPrefix("✅") ? .green : theme.error)
                    }
                }

                // Auth
                Section(header: Text("Auth")) {
                    Picker("Auth Type", selection: $viewModel.editToolAuthType) {
                        ForEach(authTypesForToolType(viewModel.editToolType), id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }

                    if authTypeNeedsKey(viewModel.editToolAuthType) {
                        HStack {
                            Group {
                                if viewModel.editToolShowKey {
                                    TextField("API Key", text: $viewModel.editToolKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.editToolKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                viewModel.editToolShowKey.toggle()
                            } label: {
                                Image(systemName: viewModel.editToolShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if authTypeNeedsClientCredentials(viewModel.editToolAuthType) {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading) {
                                Text("Client ID").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                TextField("Client ID", text: $viewModel.editToolClientId)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            VStack(alignment: .leading) {
                                Text("Client Secret").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                SecureField("Client Secret", text: $viewModel.editToolClientSecret)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                }

                // Access button — programmatic navigation
                Section {
                    if let idx = viewModel.editingToolServerIndex {
                        Button {
                            viewModel.openAccessControl(target: "tool", index: idx)
                            showAccessControl = true
                        } label: {
                            HStack {
                                Image(systemName: "lock")
                                Text("Access")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }

                // Advanced
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    // OpenAPI Spec — only for OpenAPI type
                    if viewModel.editToolType == "openapi" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAPI Spec").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            HStack {
                                Picker("", selection: $viewModel.editToolSpecType) {
                                    Text("URL").tag("url")
                                    Text("JSON").tag("json")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 80)

                                if viewModel.editToolSpecType == "url" {
                                    TextField("openapi.json", text: $viewModel.editToolSpecPath)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }

                            if viewModel.editToolSpecType == "json" {
                                TextEditor(text: $viewModel.editToolSpecJSON)
                                    .frame(minHeight: 100)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                                    )
                            }
                        }
                    }

                    // Headers
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Headers").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextEditor(text: $viewModel.editToolHeadersJSON)
                            .frame(minHeight: 60)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    // Function Filter
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Function Name Filter List").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("e.g. func1, !func2", text: $viewModel.editToolFunctionFilter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                // Delete
                Section {
                    Button(role: .destructive) {
                        viewModel.showDeleteToolServerConfirmation = true
                    } label: {
                        HStack { Spacer(); Text("Delete Connection").scaledFont(size: 16, weight: .medium); Spacer() }
                    }
                }
            }
            .navigationTitle("Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showAccessControl) {
                AccessControlView(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.editingToolServerIndex = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingEditedToolServer {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveToolServerEdit()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.editToolURL.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete Connection", isPresented: $viewModel.showDeleteToolServerConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let idx = viewModel.editingToolServerIndex else { return }
                    viewModel.editingToolServerIndex = nil
                    dismiss()
                    Task { await viewModel.deleteToolServer(at: idx) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This connection will be permanently removed.")
            }
        }
    }
}

// MARK: - Add Tool Server Sheet

struct AddToolServerSheet: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var showAdvanced = false
    @State private var showAccessControl = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Type")) {
                    Picker("Type", selection: $viewModel.addToolType) {
                        Text("OpenAPI").tag("openapi")
                        Text("MCP").tag("mcp")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Name").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("Enter name", text: $viewModel.addToolName)
                                .textInputAutocapitalization(.never)
                        }
                        VStack(alignment: .leading) {
                            Text("ID (optional)").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("auto", text: $viewModel.addToolId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Description").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("Enter description", text: $viewModel.addToolDescription)
                    }
                }

                // URL + Verify + Enable
                Section(header: Text("URL")) {
                    HStack {
                        TextField("API Base URL", text: $viewModel.addToolURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        if viewModel.isVerifyingAddToolServer {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await viewModel.verifyToolServerFromAdd() }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("", isOn: $viewModel.addToolEnable)
                            .labelsHidden()
                            .tint(theme.brandPrimary)
                    }

                    if let result = viewModel.verifyAddToolServerResult {
                        Text(result)
                            .scaledFont(size: 12)
                            .foregroundStyle(result.hasPrefix("✅") ? .green : theme.error)
                    }
                }

                // Auth
                Section(header: Text("Auth")) {
                    Picker("Auth Type", selection: $viewModel.addToolAuthType) {
                        ForEach(authTypesForToolType(viewModel.addToolType), id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }

                    if authTypeNeedsKey(viewModel.addToolAuthType) {
                        HStack {
                            Group {
                                if viewModel.addToolShowKey {
                                    TextField("API Key", text: $viewModel.addToolKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.addToolKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button { viewModel.addToolShowKey.toggle() } label: {
                                Image(systemName: viewModel.addToolShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if authTypeNeedsClientCredentials(viewModel.addToolAuthType) {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading) {
                                Text("Client ID").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                TextField("Client ID", text: $viewModel.addToolClientId)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            VStack(alignment: .leading) {
                                Text("Client Secret").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                                SecureField("Client Secret", text: $viewModel.addToolClientSecret)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                }

                // Access button — programmatic navigation
                Section {
                    Button {
                        viewModel.currentAccessGrants = []
                        viewModel.accessControlTarget = "tool_add"
                        showAccessControl = true
                    } label: {
                        HStack {
                            Image(systemName: "lock")
                            Text("Access")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    // OpenAPI Spec — only for OpenAPI type
                    if viewModel.addToolType == "openapi" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAPI Spec").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            HStack {
                                Picker("", selection: $viewModel.addToolSpecType) {
                                    Text("URL").tag("url")
                                    Text("JSON").tag("json")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 80)

                                if viewModel.addToolSpecType == "url" {
                                    TextField("openapi.json", text: $viewModel.addToolSpecPath)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }

                            if viewModel.addToolSpecType == "json" {
                                TextEditor(text: $viewModel.addToolSpecJSON)
                                    .frame(minHeight: 100)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                                    )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Headers").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextEditor(text: $viewModel.addToolHeadersJSON)
                            .frame(minHeight: 60)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Function Name Filter List").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("e.g. func1, !func2", text: $viewModel.addToolFunctionFilter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showAccessControl) {
                AccessControlView(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isShowingAddToolServer = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingAddToolServer {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.addToolServer()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.addToolURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Edit Terminal Sheet

struct EditTerminalSheet: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var showAdvanced = false
    @State private var showAccessControl = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Name").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("Enter name", text: $viewModel.editTermName)
                                .textInputAutocapitalization(.never)
                        }
                        VStack(alignment: .leading) {
                            Text("ID (optional)").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("auto", text: $viewModel.editTermId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }

                Section(header: Text("URL")) {
                    TextField("http://...", text: $viewModel.editTermURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // Access button — programmatic navigation
                Section {
                    if let idx = viewModel.editingTerminalIndex {
                        Button {
                            viewModel.openAccessControl(target: "terminal", index: idx)
                            showAccessControl = true
                        } label: {
                            HStack {
                                Image(systemName: "lock")
                                Text("Access")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }

                // Auth
                Section(header: Text("Auth")) {
                    Picker("Auth Type", selection: $viewModel.editTermAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                    }

                    if authTypeNeedsKey(viewModel.editTermAuthType) {
                        HStack {
                            Group {
                                if viewModel.editTermShowKey {
                                    TextField("API Key", text: $viewModel.editTermKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.editTermKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button { viewModel.editTermShowKey.toggle() } label: {
                                Image(systemName: viewModel.editTermShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAPI Spec").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                        TextField("/openapi.json", text: $viewModel.editTermPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                // Delete
                Section {
                    Button(role: .destructive) {
                        viewModel.showDeleteTerminalConfirmation = true
                    } label: {
                        HStack { Spacer(); Text("Delete").scaledFont(size: 16, weight: .medium); Spacer() }
                    }
                }
            }
            .navigationTitle("Edit Terminal Connection")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showAccessControl) {
                AccessControlView(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.editingTerminalIndex = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingEditedTerminal {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveTerminalEdit()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.editTermURL.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete Terminal Connection", isPresented: $viewModel.showDeleteTerminalConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let idx = viewModel.editingTerminalIndex else { return }
                    viewModel.editingTerminalIndex = nil
                    dismiss()
                    Task { await viewModel.deleteTerminal(at: idx) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This terminal connection will be permanently removed.")
            }
        }
    }
}

// MARK: - Add Terminal Sheet

struct AddTerminalSheet: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Name").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("Enter name", text: $viewModel.addTermName)
                                .textInputAutocapitalization(.never)
                        }
                        VStack(alignment: .leading) {
                            Text("ID (optional)").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary)
                            TextField("auto", text: $viewModel.addTermId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }

                Section(header: Text("URL")) {
                    TextField("http://...", text: $viewModel.addTermURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(header: Text("Auth")) {
                    Picker("Auth Type", selection: $viewModel.addTermAuthType) {
                        Text("None").tag("none")
                        Text("Bearer").tag("bearer")
                        Text("Session").tag("session")
                    }

                    if authTypeNeedsKey(viewModel.addTermAuthType) {
                        HStack {
                            Group {
                                if viewModel.addTermShowKey {
                                    TextField("API Key", text: $viewModel.addTermKey)
                                } else {
                                    SecureField("API Key", text: $viewModel.addTermKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button { viewModel.addTermShowKey.toggle() } label: {
                                Image(systemName: viewModel.addTermShowKey ? "eye.slash" : "eye")
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add Terminal Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isShowingAddTerminal = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingAddTerminal {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") {
                            Task {
                                await viewModel.addTerminal()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.addTermURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Access Control View (pushed inside NavigationStack — fixes sheet-on-sheet bug)

struct AccessControlView: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var isShowingAddAccess = false

    var body: some View {
        VStack(spacing: 0) {
            // Public/Private Toggle
            HStack(spacing: Spacing.md) {
                Image(systemName: viewModel.isCurrentAccessPublic ? "lock.open" : "lock")
                    .scaledFont(size: 20, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        Button {
                            if !viewModel.isCurrentAccessPublic { viewModel.toggleAccessMode() }
                        } label: {
                            Label("Public", systemImage: "lock.open")
                        }
                        Button {
                            if viewModel.isCurrentAccessPublic { viewModel.toggleAccessMode() }
                        } label: {
                            Label("Private", systemImage: "lock")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.isCurrentAccessPublic ? "Public" : "Private")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundStyle(theme.textPrimary)
                            Image(systemName: "chevron.down")
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    Text(viewModel.isCurrentAccessPublic
                         ? "All users can access this integration"
                         : "Only select users and groups with permission can access")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()
            }
            .padding(Spacing.md)

            Divider()

            // Access List
            if !viewModel.isCurrentAccessPublic || !viewModel.currentSpecificGrants.isEmpty {
                HStack {
                    Text("Access List")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Button {
                        viewModel.addAccessSearchQuery = ""
                        viewModel.addAccessSearchResults = []
                        viewModel.addAccessTab = .users
                        isShowingAddAccess = true
                        Task {
                            await viewModel.searchUsersForAccess()
                            await viewModel.loadGroupsForAccess()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add Access")
                        }
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xs)

                ScrollView {
                    VStack(spacing: 0) {
                        let grants = viewModel.currentSpecificGrants
                        ForEach(Array(grants.enumerated()), id: \.offset) { idx, grant in
                            accessGrantRow(grant: grant)
                            if idx < grants.count - 1 {
                                Divider()
                                    .padding(.horizontal, Spacing.md)
                            }
                        }

                        if grants.isEmpty {
                            Text("No users or groups added yet.")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, Spacing.lg)
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .navigationTitle("Access Control")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingAddAccess) {
            IntegrationAddAccessSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    private func accessGrantRow(grant: ToolAccessGrant) -> some View {
        HStack(spacing: Spacing.md) {
            if grant.principal_type == "group" {
                Image(systemName: "person.3")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(theme.surfaceContainer)
                    .clipShape(Circle())
            } else {
                let serverURL = dependencies.apiClient?.baseURL ?? ""
                UserAvatar(
                    size: 36,
                    imageURL: URL(string: "\(serverURL)/api/v1/users/\(grant.principal_id)/profile/image"),
                    name: viewModel.resolvedName(for: grant)
                )
            }

            Text(viewModel.resolvedName(for: grant))
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer()

            Text("READ")
                .scaledFont(size: 10, weight: .heavy)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Button {
                viewModel.removeAccessGrant(grant)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}

// MARK: - Add Access Sheet

struct IntegrationAddAccessSheet: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $viewModel.addAccessTab) {
                    ForEach(AdminIntegrationsViewModel.AddAccessTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                if viewModel.addAccessTab == .users {
                    // Search bar
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(theme.textTertiary)
                        TextField("Search users…", text: $viewModel.addAccessSearchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit {
                                Task { await viewModel.searchUsersForAccess() }
                            }
                            .onChange(of: viewModel.addAccessSearchQuery) { _, _ in
                                Task { await viewModel.searchUsersForAccess() }
                            }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .padding(.horizontal, Spacing.md)

                    // Results
                    if viewModel.isSearchingUsers {
                        ProgressView()
                            .padding(.top, Spacing.lg)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(viewModel.addAccessSearchResults, id: \.id) { user in
                                    let alreadyAdded = viewModel.currentAccessGrants.contains { $0.principal_id == user.id }
                                    Button {
                                        if !alreadyAdded {
                                            viewModel.addAccessGrant(principalType: "user", principalId: user.id)
                                            viewModel.resolvedUsers[user.id] = user
                                        }
                                    } label: {
                                        HStack(spacing: Spacing.md) {
                                            let serverURL = dependencies.apiClient?.baseURL ?? ""
                                            UserAvatar(
                                                size: 36,
                                                imageURL: URL(string: "\(serverURL)/api/v1/users/\(user.id)/profile/image"),
                                                name: user.name
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(user.name ?? "Unknown")
                                                    .scaledFont(size: 15, weight: .medium)
                                                    .foregroundStyle(theme.textPrimary)
                                                Text(user.email)
                                                    .scaledFont(size: 12)
                                                    .foregroundStyle(theme.textTertiary)
                                            }
                                            Spacer()
                                            if alreadyAdded {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        .padding(.horizontal, Spacing.md)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(alreadyAdded)
                                    .opacity(alreadyAdded ? 0.5 : 1)

                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                    }
                } else {
                    // Groups tab
                    ScrollView {
                        VStack(spacing: 0) {
                            if viewModel.addAccessGroups.isEmpty {
                                Text("No groups available.")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.top, Spacing.lg)
                            } else {
                                ForEach(viewModel.addAccessGroups) { group in
                                    let alreadyAdded = viewModel.currentAccessGrants.contains { $0.principal_id == group.id }
                                    Button {
                                        if !alreadyAdded {
                                            viewModel.addAccessGrant(principalType: "group", principalId: group.id)
                                        }
                                    } label: {
                                        HStack(spacing: Spacing.md) {
                                            Image(systemName: "person.3")
                                                .scaledFont(size: 16)
                                                .foregroundStyle(theme.textTertiary)
                                                .frame(width: 36, height: 36)
                                                .background(theme.surfaceContainer)
                                                .clipShape(Circle())
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(group.name)
                                                    .scaledFont(size: 15, weight: .medium)
                                                    .foregroundStyle(theme.textPrimary)
                                                if let desc = group.description, !desc.isEmpty {
                                                    Text(desc)
                                                        .scaledFont(size: 12)
                                                        .foregroundStyle(theme.textTertiary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            if alreadyAdded {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        .padding(.horizontal, Spacing.md)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(alreadyAdded)
                                    .opacity(alreadyAdded ? 0.5 : 1)

                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                    }
                    .task {
                        await viewModel.loadGroupsForAccess()
                    }
                }

                Spacer()
            }
            .navigationTitle("Add Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
