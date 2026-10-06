import SwiftUI

/// Edit Terminal → "Server Setup" (web AddTerminalServerModal): Verify detects plain terminal
/// vs orchestrator; orchestrators get a policy (image / CPU / memory / storage / idle / env),
/// lifecycle JSON and "Refresh terminals". Policy + lifecycle are written to the orchestrator
/// with "Save Policy" (the web writes them on the modal's Save).
struct TerminalServerSetupSection: View {
    @Bindable var viewModel: AdminIntegrationsViewModel
    @Environment(AppDependencyContainer.self) var dependencies

    @State var verifying = false
    @State var loadingPolicy = false
    @State var savingPolicy = false
    @State var refreshing = false
    @State var message: String?
    @State var failed = false

    // Policy (web buildPolicyData)
    @State var image = ""
    @State var cpu = "1"
    @State var memory = "1Gi"
    @State var persistent = false
    @State var storageSize = "5Gi"
    @State var idleMinutes = 30
    @State var envText = ""          // KEY=value per line
    @State var lifecycleJSON = "{}"
    @State var onlyIdle = true
    @State var resetTerminals = false

    var isOrchestrator: Bool { viewModel.editTermServerType == "orchestrator" }
    var api: APIClient? { dependencies.apiClient }
    var url: String { viewModel.editTermURL }
    var key: String { viewModel.editTermKey }
    var auth: String { viewModel.editTermAuthType }

    var body: some View {
        Section {
            HStack {
                Button { Task { await verify() } } label: {
                    if verifying { ProgressView() } else { Label("Verify Connection", systemImage: "checkmark.shield") }
                }
                .disabled(url.isEmpty || verifying)
                Spacer()
                if let t = viewModel.editTermServerType {
                    Text(t == "orchestrator" ? "Orchestrator" : "Terminal").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.18)))
                }
            }
            Toggle("Forward Cookies", isOn: $viewModel.editTermForwardCookies)
            Picker("Chat Uploads", selection: $viewModel.editTermChatUploads) {
                Text("Default").tag("default")
                Text("Save to terminal filesystem").tag("filesystem")
            }
            if isOrchestrator {
                Picker("Chat Terminal", selection: $viewModel.editTermChatContext) {
                    Text("One per user").tag("default")
                    Text("One per chat").tag("chat_id")
                    Text("Off").tag("off")
                }
                Picker("Automation Terminal", selection: $viewModel.editTermAutomationContext) {
                    Text("One per user").tag("default")
                    Text("One per automation").tag("automation_id")
                    Text("Off").tag("off")
                }
            }
        } header: { Text("Server Setup") } footer: {
            if let message { Text(message).foregroundStyle(failed ? .red : .secondary) }
        }

        if isOrchestrator {
            Section {
                TextField("Policy ID", text: $viewModel.editTermPolicyId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await loadPolicy() } }
                if loadingPolicy { ProgressView() } else {
                    TextField("Image (default)", text: $image).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        TextField("CPU", text: $cpu).textInputAutocapitalization(.never)
                        TextField("Memory", text: $memory).textInputAutocapitalization(.never)
                    }
                    Toggle("Persistent Storage", isOn: $persistent)
                    if persistent { TextField("Storage Size", text: $storageSize).textInputAutocapitalization(.never) }
                    Stepper("Idle Timeout: \(idleMinutes) min", value: $idleMinutes, in: 0...1440, step: 5)
                    VStack(alignment: .leading) {
                        Text("Environment (KEY=value per line)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $envText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 60)
                    }
                    VStack(alignment: .leading) {
                        Text("Lifecycle (JSON)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $lifecycleJSON).font(.system(.footnote, design: .monospaced)).frame(minHeight: 60)
                    }
                    Button { Task { await savePolicy() } } label: {
                        if savingPolicy { ProgressView() } else { Label("Save Policy", systemImage: "square.and.arrow.down") }
                    }
                    .disabled(viewModel.editTermPolicyId.isEmpty || savingPolicy)
                }
            } header: { Text("Policy") }

            Section {
                Toggle("Only idle terminals", isOn: $onlyIdle)
                Toggle("Reset (discard terminal state)", isOn: $resetTerminals)
                Button { Task { await refresh() } } label: {
                    if refreshing { ProgressView() } else { Label("Refresh Terminals", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(viewModel.editTermPolicyId.isEmpty || refreshing)
            } header: { Text("Terminals") } footer: {
                Text("Restarts terminals so they pick up the current policy.")
            }
            .task(id: viewModel.editTermPolicyId.isEmpty) { await loadPolicy() }
        }
    }
}
