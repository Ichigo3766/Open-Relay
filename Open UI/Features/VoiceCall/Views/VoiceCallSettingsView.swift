import SwiftUI

/// Settings for voice calls: listening/voice engines, turn-taking, barge-in.
struct VoiceCallSettingsView: View {
    @Environment(AppDependencyContainer.self) private var dependencies

    private struct Option: Identifiable {
        let id: String
        let label: String
        let detail: String
    }

    private let sttOptions: [Option] = [
        Option(id: "apple", label: "Apple Speech", detail: "Fast live transcription, works offline"),
        Option(id: "parakeet", label: "Parakeet (on-device)", detail: "High accuracy, ~600 MB download on first call"),
        Option(id: "qwen3", label: "Qwen3 ASR (on-device)", detail: "Multilingual, ~700 MB download on first call"),
        Option(id: "server", label: "Server (OpenWebUI)", detail: "Transcribed by your server after you finish speaking"),
    ]

    var body: some View {
        @Bindable var settings = dependencies.voiceCallSettings
        List {
            Section {
                Picker("Call Mode", selection: $settings.useRealtimeBridge) {
                    Text("Standard").tag(false)
                    Text("Realtime").tag(true)
                        .disabled(dependencies.authViewModel.backendConfig?.audio?.realtime?.enabled != true)
                }
            } footer: {
                Text("Realtime uses the server's voice and turn-taking, with your selected chat model and tools. Enable it in the server's Audio settings.")
            }
            if settings.useRealtimeBridge {
                Section { Toggle("Start on Speaker", isOn: $settings.defaultSpeakerOn) }
            } else {
                Section {
                    ForEach(sttOptions) { option in
                        row(option, selected: settings.sttEngine == option.id) {
                            settings.sttEngine = option.id
                        }
                    }
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Apple Speech uses the newer iOS 26 recogniser when your language supports it. If the selected engine can't start, calls fall back to Apple Speech.")
                }

                Section {
                    NavigationLink {
                        TTSSettingsView()
                    } label: {
                        LabeledContent("Voice", value: "Same as Assistant's Voice")
                    }
                } footer: {
                    Text("Calls speak with the voice you choose in Assistant's Voice.")
                }

                Section {
                    Picker("Pause Before Replying", selection: $settings.turnPace) {
                        ForEach(TurnPace.allCases, id: \.self) { pace in
                            Text(pace.displayName).tag(pace)
                        }
                    }
                    .disabled(settings.customPauseEnabled)
                    Picker("Sensitivity", selection: $settings.vadSensitivity) {
                        ForEach(VADSensitivity.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    Toggle("Interrupt by Speaking", isOn: $settings.bargeInEnabled)
                        .disabled(!settings.vadEnabled)
                    Toggle("Start on Speaker", isOn: $settings.defaultSpeakerOn)
                } header: {
                    Text("Conversation")
                } footer: {
                    Text(conversationFooter(settings))
                }

                Section {
                    NavigationLink {
                        VoiceCallAdvancedView()
                    } label: {
                        LabeledContent("Advanced", value: settings.hasAdvancedChanges ? "Customised" : "Default")
                    }
                } footer: {
                    Text("Turn voice detection or Smart Turn off, set exact pause times, tune interruptions and show live diagnostics.")
                }
            }
        }
        .navigationTitle("Voice Calls")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func conversationFooter(_ s: VoiceCallSettings) -> String {
        var text = "Relaxed gives you time to pause and think mid-sentence. Lower sensitivity helps the assistant hear you in noisy places."
        if s.customPauseEnabled { text += " Pause is set in Advanced." }
        if !s.vadEnabled { text += " Interrupting needs Voice Detection (Advanced)." }
        return text
    }

    private func row(_ option: Option, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.play(.light)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).foregroundStyle(.primary)
                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
