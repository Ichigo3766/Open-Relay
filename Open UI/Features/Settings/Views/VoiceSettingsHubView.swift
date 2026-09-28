import SwiftUI
import AVFoundation

/// Settings → Voice. One place for everything voice-related:
///
/// - **Assistant's Voice** — how the assistant speaks (Read Aloud *and* calls).
/// - **Your Voice** — the language you speak, dictation, audio files.
/// - **Voice Calls** — listening engine and turn-taking for live calls.
/// - **Models & Storage** — every downloaded voice model in one list.
///
/// Also opened from the in-call settings button (`presentedInCall`).
struct VoiceSettingsHubView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    var presentedInCall = false

    @AppStorage("ttsEngine") private var ttsEngine = "system"
    @AppStorage("ttsOnDeviceModel") private var onDeviceModel = "kokoro"
    @AppStorage("ttsKokoroVoice") private var kokoroVoice = "af_heart"
    @AppStorage("ttsQwen3Voice") private var qwen3Voice = "Aiden"
    @AppStorage("ttsVoiceIdentifier") private var systemVoice = ""
    @AppStorage("sttLocale") private var sttLocale = ""
    @AppStorage("sttEngine") private var dictationEngine = "device"

    var body: some View {
        let calls = dependencies.voiceCallSettings
        List {
            Section {
                NavigationLink {
                    TTSSettingsView()
                } label: {
                    row("Assistant's Voice", icon: "waveform", detail: assistantVoiceSummary)
                }
            } footer: {
                Text("How the assistant speaks when reading messages aloud and during voice calls.")
            }

            Section {
                NavigationLink {
                    STTSettingsView()
                } label: {
                    row("Your Voice", icon: "mic", detail: "\(languageSummary) · Dictation: \(dictationSummary)")
                }
            } footer: {
                Text("The language you speak, dictation in the message box, and transcription of attached audio.")
            }

            Section {
                NavigationLink {
                    VoiceCallSettingsView()
                } label: {
                    row("Voice Calls", icon: "phone.connection", detail: callSummary(calls))
                }
            } footer: {
                Text("Listening engine, pauses, sensitivity and interruptions for live voice calls.")
            }

            Section {
                NavigationLink {
                    VoiceModelsStorageView()
                } label: {
                    row("Models & Storage", icon: "externaldrive", detail: "Downloaded voice models")
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentedInCall {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
        }
    }

    private func row(_ title: String, icon: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    // MARK: Summaries

    private var assistantVoiceSummary: String {
        switch ttsEngine {
        case "ondevice", "kokoro", "qwen3", "marvis", "mlx":
            let qwen = ttsEngine == "qwen3" || (ttsEngine == "ondevice" && onDeviceModel == "qwen3")
            return qwen ? "Qwen3 · \(qwen3Voice)" : "Kokoro · \(kokoroVoiceName)"
        case "server":
            return "Server voice"
        case "auto":
            return "Auto (best available)"
        default:
            let name = systemVoice.isEmpty ? "Auto" : (AVSpeechSynthesisVoice(identifier: systemVoice)?.name ?? "Custom")
            return "System · \(name)"
        }
    }

    private var kokoroVoiceName: String {
        KokoroVoiceCatalog.groups.flatMap(\.voices).first { $0.id == kokoroVoice }?.name ?? kokoroVoice
    }

    private var languageSummary: String {
        sttLocale.isEmpty ? "Device language" : (Locale.current.localizedString(forIdentifier: sttLocale) ?? sttLocale)
    }

    private var dictationSummary: String {
        dictationEngine == "server" ? "Server" : "On-Device"
    }

    private func callSummary(_ s: VoiceCallSettings) -> String {
        let listening: String
        switch s.sttEngine {
        case "parakeet": listening = "Parakeet"
        case "qwen3":    listening = "Qwen3"
        case "server":   listening = "Server"
        default:         listening = "Apple Speech"
        }
        let pace = s.customPauseEnabled ? "Custom pause" : s.turnPace.displayName.replacingOccurrences(of: " (default)", with: "")
        var parts = [listening, pace]
        if s.hasAdvancedChanges { parts.append("Advanced changed") }
        return parts.joined(separator: " · ")
    }
}
