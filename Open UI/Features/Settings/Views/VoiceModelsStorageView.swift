import SwiftUI

/// Settings → Voice → Models & Storage. Every downloaded voice model in one
/// list, grouped by what it's for, with size and swipe-to-delete.
struct VoiceModelsStorageView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var sizes: [Model: Int64] = [:]
    @State private var pendingDelete: Model?

    enum Model: String, CaseIterable, Identifiable {
        case kokoro, qwen3TTS, qwen3ASR, fourier, parakeet, voiceDetection
        var id: String { rawValue }

        var title: String {
            switch self {
            case .kokoro:         return "Kokoro"
            case .qwen3TTS:       return "Qwen3 TTS"
            case .fourier:        return "Oruk Fourier 2B"
            case .qwen3ASR:       return "Qwen3 ASR"
            case .parakeet:       return "Parakeet"
            case .voiceDetection: return "Voice Detection"
            }
        }

        var detail: String {
            switch self {
            case .kokoro:         return "On-device assistant voice"
            case .qwen3TTS:       return "On-device assistant voice (multilingual)"
            case .fourier:        return "English dictation and audio files"
            case .qwen3ASR:       return "Dictation, audio files, calls"
            case .parakeet:       return "Voice call listening"
            case .voiceDetection: return "Silero + Smart Turn for calls · re-downloads automatically"
            }
        }
    }

    var body: some View {
        List {
            section("Speaking", [.kokoro, .qwen3TTS])
            section("Listening", [.qwen3ASR, .fourier, .parakeet])
            section("Voice Calls", [.voiceDetection])
            Section {
                LabeledContent("Apple Speech", value: "Managed by iOS")
            } footer: {
                Text("Apple's speech recognition models are downloaded and managed by iOS (Settings → General → Keyboard).")
            }
        }
        .navigationTitle("Models & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Delete \(pendingDelete?.title ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let m = pendingDelete { delete(m) }
                pendingDelete = nil
            }
        } message: {
            Text("It will be downloaded again the next time it's needed.")
        }
    }

    private func section(_ title: String, _ models: [Model]) -> some View {
        Section(title) {
            ForEach(models) { model in
                let size = sizes[model] ?? 0
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                        Text(model.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "Not downloaded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if size > 0 {
                        Button(role: .destructive) { pendingDelete = model } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func refresh() {
        let s = StorageManager.shared
        sizes = [
            .kokoro: s.kokoroTTSModelSize(),
            .qwen3TTS: s.qwen3TTSModelSize(),
            .qwen3ASR: s.asrModelSize(),
            .fourier: s.asrModelSize(.fourier),
            .parakeet: s.parakeetModelSize(),
            .voiceDetection: s.voiceDetectionModelSize(),
        ]
    }

    private func delete(_ model: Model) {
        let tts = dependencies.textToSpeechService
        let selected = tts.kokoroService.config.activeModel
        switch model {
        case .kokoro:
            tts.kokoroService.config.activeModel = .kokoro
            tts.kokoroService.unloadAndDeleteModel()
            tts.kokoroService.config.activeModel = selected
        case .qwen3TTS:
            tts.kokoroService.config.activeModel = .qwen3
            tts.kokoroService.unloadAndDeleteModel()
            tts.kokoroService.config.activeModel = selected
        case .fourier:
            dependencies.asrService.unloadAndDeleteVariant(.fourier)
        case .qwen3ASR:
            dependencies.asrService.unloadAndDeleteVariant(.qwen3ASR)
        case .parakeet:
            StorageManager.shared.deleteParakeetModelFiles()
        case .voiceDetection:
            dependencies.vadModelStore.unload()
            StorageManager.shared.deleteVoiceDetectionModelFiles()
        }
        Haptics.play(.light)
        refresh()
    }
}
