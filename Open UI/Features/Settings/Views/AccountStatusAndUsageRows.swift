import SwiftUI

/// Settings → Account: "Set Status" (web UserMenu → UserStatusModal) and the active-users
/// count with running models (web UserMenu, `/api/usage`). Both are server-gated.
struct AccountStatusAndUsageRows: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var emoji = ""
    @State private var message = ""
    @State private var usage: UsageInfo?
    @State private var showEditor = false

    private var features: BackendConfig.BackendFeatures? { dependencies.authViewModel.backendConfig?.features }
    private var isAdmin: Bool { dependencies.authViewModel.currentUser?.role == .admin }
    private var statusEnabled: Bool { features?.enableUserStatus ?? false }
    private var usageVisible: Bool { isAdmin || (features?.enablePublicActiveUsersCount ?? false) }

    var body: some View {
        Group {
            if statusEnabled {
                SettingsCell(
                    icon: "face.smiling",
                    title: emoji.isEmpty && message.isEmpty ? "Set Status" : "\(emoji) \(message)".trimmingCharacters(in: .whitespaces),
                    subtitle: emoji.isEmpty && message.isEmpty ? "Let others know what you're up to" : "Tap to change or clear",
                    iconColor: .yellow,
                    showDivider: usageVisible && usage != nil,
                    accessory: .chevron
                ) { showEditor = true }
            }
            if usageVisible, let usage {
                SettingsCell(
                    icon: "person.2.wave.2",
                    title: "Active Users: \(usage.userCount)",
                    subtitle: usage.modelIds.isEmpty ? "No models running" : "Running: \(usage.modelIds.joined(separator: ", "))",
                    iconColor: .green,
                    showDivider: false,
                    accessory: .none
                ) {}
            }
        }
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            UserStatusEditor(emoji: emoji, message: message) { e, m in
                emoji = e; message = m
            }
            .presentationDetents([.medium])
        }
    }

    private func load() async {
        guard let api = dependencies.apiClient else { return }
        if statusEnabled, let s = try? await api.getMyStatus() {
            emoji = s.emoji; message = s.message
        }
        if usageVisible { usage = try? await api.getUsage() }
    }
}

private struct UserStatusEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    @State var emoji: String
    @State var message: String
    let onSaved: (String, String) -> Void
    @State private var isSaving = false
    @State private var error: String?

    private let quickEmojis = ["💬", "📅", "🤒", "🌴", "🏠", "🎧", "🚗", "🍽️", "🔕", "🚀"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        TextField("😀", text: $emoji)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .onChange(of: emoji) { _, v in if v.count > 1 { emoji = String(v.suffix(1)) } }
                        TextField("What's your status?", text: $message)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(quickEmojis, id: \.self) { e in Button(e) { emoji = e }.buttonStyle(.plain).font(.title3) } }
                    }
                }
                if !emoji.isEmpty || !message.isEmpty {
                    Section {
                        Button("Clear Status", role: .destructive) { Task { await save(emoji: "", message: "") } }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Set Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView() } else {
                        Button("Save") { Task { await save(emoji: emoji, message: message.trimmingCharacters(in: .whitespaces)) } }
                    }
                }
            }
        }
    }

    private func save(emoji: String, message: String) async {
        guard let api = dependencies.apiClient else { return }
        isSaving = true
        do {
            try await api.updateMyStatus(emoji: emoji, message: message)
            onSaved(emoji, message)
            Haptics.notify(.success)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
