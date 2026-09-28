import SwiftUI

struct ChannelWebhooksView: View {
    @State private var vm: ChannelWebhooksViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var editing: ChannelWebhook?
    @State private var deleting: ChannelWebhook?
    @State private var copied = false

    init(apiClient: APIClient, channelId: String) {
        _vm = State(initialValue: ChannelWebhooksViewModel(apiClient: apiClient, channelId: channelId))
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = vm.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { Task { await vm.load() } }
                    }
                }
                Section {
                    if vm.isBusy { ProgressView().accessibilityLabel("Loading webhooks") }
                    if vm.webhooks.isEmpty && !vm.isBusy && vm.errorMessage == nil {
                        Text("No webhooks yet").foregroundStyle(.secondary)
                    }
                    ForEach(vm.webhooks) { webhook in
                        HStack {
                            Text(webhook.name)
                            Spacer()
                            Menu {
                                Button("Copy Webhook URL", systemImage: "doc.on.doc") {
                                    if let url = vm.postingURL(for: webhook) {
                                        UIPasteboard.general.setItems([["public.url": url]],
                                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                                        copied = true
                                    }
                                }
                                Button("Rename", systemImage: "pencil") { editing = webhook }
                                Button("Delete Webhook", systemImage: "trash", role: .destructive) { deleting = webhook }
                            } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("Actions for \(webhook.name)")
                        }
                    }
                } footer: {
                    Text("Anyone with a webhook URL can post to this channel. Keep it private; deleting the webhook revokes it.")
                }
            }
            .disabled(vm.isBusy)
            .navigationTitle("Webhooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close").disabled(vm.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Webhook").disabled(vm.isBusy || vm.errorMessage != nil)
                }
            }
            .task { await vm.load() }
            .sheet(isPresented: $showCreate) { ChannelWebhookEditor(vm: vm).themed() }
            .sheet(item: $editing) { ChannelWebhookEditor(vm: vm, webhook: $0).themed() }
            .confirmationDialog("Delete Webhook?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Webhook", role: .destructive) {
                    if let deleting { Task { await vm.delete(deleting) } }
                    deleting = nil
                }
            } message: { Text("Its URL will stop accepting messages. This cannot be undone.") }
            .alert("Webhook URL Copied", isPresented: $copied) {
                Button("OK", role: .cancel) {}
            } message: { Text("Paste it into a trusted integration. The clipboard copy expires in five minutes.") }
        }
        .interactiveDismissDisabled(vm.isBusy)
    }
}

private struct ChannelWebhookEditor: View {
    @Bindable var vm: ChannelWebhooksViewModel
    var webhook: ChannelWebhook?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(vm: ChannelWebhooksViewModel, webhook: ChannelWebhook? = nil) {
        self.vm = vm
        self.webhook = webhook
        _name = State(initialValue: webhook?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(vm.isBusy)
            .navigationTitle(webhook == nil ? "New Webhook" : "Rename Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel").disabled(vm.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            do { try await vm.save(webhook, name: name); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        if vm.isBusy { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .accessibilityLabel("Save").disabled(vm.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(vm.isBusy)
    }
}
