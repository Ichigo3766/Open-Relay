import SwiftUI

// MARK: - Admin Sub-agents Settings View (v0.11.0)

/// Admin console Settings → Sub-agents section.
/// Matches the web UI fields: enable, max concurrent, background enabled,
/// max background, max iterations, max output, system prompt.
struct AdminSubagentsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminSubagentsViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // MARK: Sub-agents Section
                    subagentsSection
                        .padding(.top, Spacing.md)

                    Spacer(minLength: 100)
                }
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
            if let error = viewModel.saveError {
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
                    } else if viewModel.saveSuccess {
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
                .background(viewModel.saveSuccess ? Color.green : theme.brandPrimary)
                .clipShape(Capsule())
                .shadow(
                    color: (viewModel.saveSuccess ? Color.green : theme.brandPrimary).opacity(0.4),
                    radius: 8, x: 0, y: 4
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .animation(.easeInOut(duration: 0.2), value: viewModel.saveSuccess)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
        .animation(.easeInOut(duration: 0.25), value: viewModel.saveError)
    }

    // MARK: - Sub-agents Section

    private var subagentsSection: some View {
        VStack(spacing: Spacing.sm) {
            // Section header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person.2.circle")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Text("SUB-AGENTS")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, Spacing.screenPadding)

            if viewModel.isLoading {
                loadingView
            } else {
                SettingsSection {
                    // ── Enable Sub-agents ──
                    VStack(spacing: 0) {
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("Enable sub-agents")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Allow the AI to delegate tasks to sub-agents. Each sub-agent creates a real chat with full tool access. Uses additional LLM calls.")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.config.enableSubagents)
                                .labelsHidden()
                                .tint(theme.brandPrimary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.chatBubblePadding)

                        if viewModel.config.enableSubagents {
                            Divider().padding(.leading, Spacing.md)

                            // ── Max Concurrent ──
                            numberRow(
                                title: "Max concurrent",
                                placeholder: "e.g. 20",
                                suffix: "simultaneous sub-agents",
                                value: $viewModel.config.maxConcurrent
                            )

                            Divider().padding(.leading, Spacing.md)

                            // ── Enable Background Sub-agents ──
                            HStack(spacing: Spacing.md) {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text("Enable background sub-agents")
                                        .scaledFont(size: 15)
                                        .foregroundStyle(theme.textPrimary)
                                    Text("Allow delegated sub-agents to keep running while the parent chat continues.")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: $viewModel.config.backgroundEnabled)
                                    .labelsHidden()
                                    .tint(theme.brandPrimary)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.chatBubblePadding)

                            Divider().padding(.leading, Spacing.md)

                            // ── Max Background ──
                            numberRow(
                                title: "Max background",
                                placeholder: "e.g. 20",
                                suffix: "background sub-agents",
                                value: $viewModel.config.maxAsync
                            )

                            Divider().padding(.leading, Spacing.md)

                            // ── Max Iterations ──
                            numberRow(
                                title: "Max iterations",
                                placeholder: "e.g. 30",
                                suffix: "tool loops per sub-agent",
                                value: $viewModel.config.maxIterations
                            )

                            Divider().padding(.leading, Spacing.md)

                            // ── Max Output ──
                            numberRow(
                                title: "Max output",
                                placeholder: "e.g. 30000",
                                suffix: "chars",
                                value: $viewModel.config.maxOutput
                            )

                            Divider().padding(.leading, Spacing.md)

                            // ── System Prompt ──
                            systemPromptRow
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reusable number row

    private func numberRow(title: String, placeholder: String, suffix: String, value: Binding<Int>) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Text(title)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            HStack(spacing: Spacing.xs) {
                TextField(placeholder, value: value, format: .number)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 6)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                Text(suffix)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - System Prompt row

    private var systemPromptRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("System prompt")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)

            ZStack(alignment: .topLeading) {
                if viewModel.config.systemPrompt.isEmpty {
                    Text("You are a sub-agent...")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.config.systemPrompt)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            }
            .padding(Spacing.xs)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )

            Text("Leave empty for the built-in default.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private var loadingView: some View {
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
}
