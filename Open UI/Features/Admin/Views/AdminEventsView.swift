import SwiftUI

// MARK: - Admin Events View

/// Admin Settings → Events — manage event webhooks with per-event filtering and user/group targeting.
struct AdminEventsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminEventsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                if viewModel.isLoading {
                    loadingState
                } else {
                    webhooksSection
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
            EventWebhookEditorSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading events…").scaledFont(size: 16).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 100)
    }

    // MARK: - Webhooks Section

    private var webhooksSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header with + button
            HStack {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.brandPrimary)
                    Text("WEBHOOKS")
                        .scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary).tracking(0.8)
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

            if viewModel.webhooks.isEmpty {
                SettingsSection(footer: "Send product events as JSON to external services.") {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.triangle.2.circlepath").scaledFont(size: 28).foregroundStyle(theme.textTertiary)
                        Text("No event webhooks configured.")
                            .scaledFont(size: 14).foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Spacing.lg)
                }
            } else {
                SettingsSection(footer: "Send product events as JSON to external services.") {
                    ForEach(Array(viewModel.webhooks.enumerated()), id: \.element.id) { index, webhook in
                        webhookRow(webhook, isLast: index == viewModel.webhooks.count - 1)
                    }
                }
            }

            if let err = viewModel.error {
                errorBanner(err)
            }
        }
    }

    private func webhookRow(_ webhook: EventWebhook, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(webhook.id == "default" ? "Default webhook" : webhook.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(webhook.enabled ? theme.textPrimary : theme.textTertiary)
                    HStack(spacing: 4) {
                        Text(webhook.urlHost).scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                        Text("·").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                        Text(webhook.eventSummary).scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                    }
                    .opacity(webhook.enabled ? 1 : 0.5)
                }
                Spacer()
                Button {
                    viewModel.openEdit(webhook)
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "gearshape").scaledFont(size: 15).foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { webhook.enabled },
                    set: { _ in Task { await viewModel.toggleWebhook(webhook) } }
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

// MARK: - Event Webhook Editor Sheet

struct EventWebhookEditorSheet: View {
    @Bindable var viewModel: AdminEventsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                // Name + URL
                Section {
                    TextField("Name", text: $viewModel.editorName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        TextField("https://example.com/events", text: $viewModel.editorURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Toggle("", isOn: $viewModel.editorEnabled).labelsHidden().tint(theme.brandPrimary)
                    }
                } header: { Text("Webhook") }

                // Target scope
                Section {
                    Picker("Send events for", selection: $viewModel.editorTargetMode) {
                        ForEach(AdminEventsViewModel.TargetMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text(targetModeDescription)
                }

                // Events
                Section {
                    Toggle("All events", isOn: Binding(
                        get: { viewModel.isAllEvents },
                        set: { viewModel.isAllEvents = $0 }
                    ))
                    .tint(theme.brandPrimary)

                    if !viewModel.isAllEvents {
                        if !viewModel.editorEvents.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(viewModel.editorEvents, id: \.self) { event in
                                        HStack(spacing: 4) {
                                            Text(event).scaledFont(size: 12, design: .monospaced)
                                            Button { viewModel.removeEventFilter(event) } label: {
                                                Image(systemName: "xmark").scaledFont(size: 10)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(theme.brandPrimary.opacity(0.1))
                                        .clipShape(Capsule())
                                        .foregroundStyle(theme.brandPrimary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }

                        // Search + catalog
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                            TextField("Search or filter events", text: $viewModel.editorEventSearchText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }

                        ForEach(viewModel.filteredCatalog) { item in
                            Button {
                                viewModel.toggleEvent(item.event)
                            } label: {
                                HStack {
                                    Image(systemName: viewModel.editorEvents.contains(item.event) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(viewModel.editorEvents.contains(item.event) ? theme.brandPrimary : theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.event).scaledFont(size: 13, design: .monospaced).foregroundStyle(theme.textPrimary)
                                        if !item.message.isEmpty {
                                            Text(item.message).scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Events")
                } footer: {
                    Text("Use broad patterns like user.* for integrations that should continue across new related events.")
                }

                // Delete (edit mode only)
                if viewModel.editingWebhookId != nil {
                    Section {
                        Button(role: .destructive) {
                            viewModel.showDeleteConfirm = true
                        } label: {
                            HStack { Spacer(); Text("Delete Webhook"); Spacer() }
                        }
                    }
                }
            }
            .navigationTitle(viewModel.editingWebhookId != nil ? "Edit Webhook" : "Add Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showEditor = false; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveWebhook()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(viewModel.editorURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete Webhook", isPresented: $viewModel.showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = viewModel.editingWebhookId {
                        Task { await viewModel.deleteWebhook(id: id); dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This webhook will be permanently removed.")
            }
        }
    }

    private var targetModeDescription: String {
        switch viewModel.editorTargetMode {
        case .all: return "Receives matching events across the instance, including system/config events and events associated with any user."
        case .system: return "Receives matching events that are not associated with a user."
        case .selected: return "Receives matching user-associated events only when the actor or user matches. System/config events are not sent."
        }
    }
}
