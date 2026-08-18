import SwiftUI

/// Sheet shown when the user taps the voice call button but the on-device TTS model
/// (Kokoro or Qwen3) hasn't been downloaded yet.
///
/// - Shows which model is needed and its estimated size.
/// - "Download" button triggers the download via `OnDeviceTTSService.loadModel()`.
/// - Live progress bar driven by `OnDeviceTTSService.downloadProgress`.
/// - Auto-dismisses and fires `onReady` once the model reaches `.ready`.
/// - Cancel button aborts without downloading.
struct VoiceCallModelDownloadSheet: View {
    let ttsService: TextToSpeechService
    /// Called when the model is ready — the caller should open the voice call.
    let onReady: () -> Void
    /// Called when the user cancels — the sheet is dismissed without opening the call.
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var isDownloading = false
    @State private var didFire = false

    // MARK: - Derived state from ttsService

    private var kokoroService: OnDeviceTTSService { ttsService.kokoroService }
    private var modelName: String { kokoroService.config.activeModel.displayName }
    private var modelSize: String { kokoroService.config.activeModel.estimatedSize }
    private var downloadProgress: Double { kokoroService.downloadProgress }
    private var modelState: KokoroTTSState { kokoroService.state }

    private var isInProgress: Bool {
        modelState == .downloading || modelState == .loading
    }

    private var statusText: String {
        switch modelState {
        case .downloading:
            if downloadProgress > 0 {
                return "Downloading… \(Int(downloadProgress * 100))%"
            } else {
                return "Starting download…"
            }
        case .loading:
            return "Loading model…"
        default:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // Icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 20)

            // Title
            Text("Voice Model Required")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            // Body
            Text("Voice calls use the **\(modelName)** on-device speech model (\(modelSize)). Download it once and it stays on your device.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            // Progress area
            if isInProgress {
                VStack(spacing: 10) {
                    ProgressView(value: downloadProgress > 0 ? downloadProgress : nil)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 280)

                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Download / Cancel buttons
            VStack(spacing: 12) {
                if !isInProgress {
                    Button {
                        startDownload()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Download \(modelName)")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .pressEffect()
                    .padding(.horizontal, 24)
                }

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.08))
        )
        .onChange(of: modelState) { _, newState in
            if newState == .ready && !didFire {
                didFire = true
                onReady()
            }
        }
    }

    private func startDownload() {
        isDownloading = true
        Task {
            try? await kokoroService.loadModel()
        }
    }
}

// MARK: - Helper: Check if TTS needs a download before voice call

extension TextToSpeechService {
    /// Returns true if on-device TTS is required but the model is not yet downloaded/ready.
    /// In this case the caller should show `VoiceCallModelDownloadSheet` instead of opening the call.
    var needsOnDeviceModelDownload: Bool {
        let engine = preferredEngine
        guard engine == .kokoro || engine == .qwen3 || engine == .auto else { return false }
        guard kokoroService.isAvailable else { return false }
        return kokoroService.state == .unloaded
    }
}
