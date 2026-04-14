import SwiftUI

// MARK: - Admin Code Execution View

/// The admin "Code Execution" tab — configure code execution and code interpreter settings.
struct AdminCodeExecutionView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminCodeExecutionViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // MARK: Code Execution Section
                    codeExecutionSection

                    // MARK: Code Interpreter Section
                    codeInterpreterSection

                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            // MARK: Floating Save Button
            floatingSaveButton
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.load()
        }
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            // Error pill above the button
            if let error = viewModel.error {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 11)
                    Text(error)
                        .scaledFont(size: 12)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(theme.error)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                Task { await viewModel.save() }
                Haptics.play(.light)
            } label: {
                HStack(spacing: Spacing.xs) {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else if viewModel.success {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                        Text("Saved")
                            .scaledFont(size: 14, weight: .semibold)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Save")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(viewModel.success ? Color.green : theme.brandPrimary)
                .clipShape(Capsule())
                .shadow(color: (viewModel.success ? Color.green : theme.brandPrimary).opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .animation(.easeInOut(duration: 0.2), value: viewModel.success)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isSaving)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
        .animation(.easeInOut(duration: 0.25), value: viewModel.error)
    }

    // MARK: - Code Execution Section

    private var codeExecutionSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "terminal", title: "Code Execution")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "Enable Code Execution",
                        subtitle: "Allow code to be executed on the server.",
                        isOn: $viewModel.config.enableCodeExecution
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlinePickerRow(
                        title: "Engine",
                        selection: $viewModel.config.codeExecutionEngine,
                        options: [
                            ("pyodide", "Pyodide"),
                            ("jupyter", "Jupyter")
                        ]
                    )

                    if viewModel.config.codeExecutionEngine == "jupyter" {
                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Jupyter URL",
                            placeholder: "http://localhost:8888",
                            text: $viewModel.config.codeExecutionJupyterURL,
                            keyboardType: .URL
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlinePickerRow(
                            title: "Authentication",
                            selection: $viewModel.config.codeExecutionJupyterAuth,
                            options: [
                                ("", "None"),
                                ("token", "Token"),
                                ("password", "Password")
                            ]
                        )

                        if viewModel.config.codeExecutionJupyterAuth == "token" {
                            Divider().padding(.leading, Spacing.md)
                            inlineSecureRow(
                                title: "Auth Token",
                                placeholder: "Token",
                                text: $viewModel.config.codeExecutionJupyterAuthToken,
                                isVisible: viewModel.showExecAuthToken,
                                onToggleVisibility: { viewModel.showExecAuthToken.toggle() }
                            )
                        }

                        if viewModel.config.codeExecutionJupyterAuth == "password" {
                            Divider().padding(.leading, Spacing.md)
                            inlineSecureRow(
                                title: "Auth Password",
                                placeholder: "Password",
                                text: $viewModel.config.codeExecutionJupyterAuthPassword,
                                isVisible: viewModel.showExecAuthPassword,
                                onToggleVisibility: { viewModel.showExecAuthPassword.toggle() }
                            )
                        }

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Timeout (seconds)",
                            placeholder: "60",
                            text: Binding(
                                get: { String(viewModel.config.codeExecutionJupyterTimeout) },
                                set: { viewModel.config.codeExecutionJupyterTimeout = Int($0) ?? 60 }
                            ),
                            keyboardType: .numberPad,
                            showDivider: false
                        )
                    }
                }
            }
        }
    }

    // MARK: - Code Interpreter Section

    private var codeInterpreterSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "play.circle", title: "Code Interpreter")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "Enable Code Interpreter",
                        subtitle: "Allow the AI to generate and execute code during conversations.",
                        isOn: $viewModel.config.enableCodeInterpreter
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlinePickerRow(
                        title: "Engine",
                        selection: $viewModel.config.codeInterpreterEngine,
                        options: [
                            ("pyodide", "Pyodide"),
                            ("jupyter", "Jupyter")
                        ]
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextAreaRow(
                        title: "Prompt Template",
                        placeholder: "Custom prompt template for code interpreter…",
                        text: $viewModel.config.codeInterpreterPromptTemplate
                    )

                    if viewModel.config.codeInterpreterEngine == "jupyter" {
                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Jupyter URL",
                            placeholder: "http://localhost:8888",
                            text: $viewModel.config.codeInterpreterJupyterURL,
                            keyboardType: .URL
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlinePickerRow(
                            title: "Authentication",
                            selection: $viewModel.config.codeInterpreterJupyterAuth,
                            options: [
                                ("", "None"),
                                ("token", "Token"),
                                ("password", "Password")
                            ]
                        )

                        if viewModel.config.codeInterpreterJupyterAuth == "token" {
                            Divider().padding(.leading, Spacing.md)
                            inlineSecureRow(
                                title: "Auth Token",
                                placeholder: "Token",
                                text: $viewModel.config.codeInterpreterJupyterAuthToken,
                                isVisible: viewModel.showInterpreterAuthToken,
                                onToggleVisibility: { viewModel.showInterpreterAuthToken.toggle() }
                            )
                        }

                        if viewModel.config.codeInterpreterJupyterAuth == "password" {
                            Divider().padding(.leading, Spacing.md)
                            inlineSecureRow(
                                title: "Auth Password",
                                placeholder: "Password",
                                text: $viewModel.config.codeInterpreterJupyterAuthPassword,
                                isVisible: viewModel.showInterpreterAuthPassword,
                                onToggleVisibility: { viewModel.showInterpreterAuthPassword.toggle() }
                            )
                        }

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Timeout (seconds)",
                            placeholder: "60",
                            text: Binding(
                                get: { String(viewModel.config.codeInterpreterJupyterTimeout) },
                                set: { viewModel.config.codeInterpreterJupyterTimeout = Int($0) ?? 60 }
                            ),
                            keyboardType: .numberPad,
                            showDivider: false
                        )
                    }
                }
            }
        }
    }

    // MARK: - Shared Row Builders

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)

            Text(title.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)

            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func sectionLoadingView() -> some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, Spacing.lg)
            Spacer()
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func inlineToggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextAreaRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text, axis: .vertical)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlinePickerRow(
        title: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            Picker("", selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .tint(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func inlineSecureRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isVisible: Bool,
        onToggleVisibility: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                Group {
                    if isVisible {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Spacer()

            Button(action: onToggleVisibility) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }
}
