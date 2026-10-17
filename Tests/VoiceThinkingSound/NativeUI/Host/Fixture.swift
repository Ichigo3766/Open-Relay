import SwiftUI
import AVFoundation

// Isolated shell around the unchanged production settings screen.
@MainActor @Observable final class AppDependencyContainer {
    let voiceCallSettings = VoiceCallSettings()
    let authViewModel = Auth()
}
struct Auth { var backendConfig: Config? = Config() }
struct Config { var audio: Audio? = Audio() }
struct Audio { var realtime: Realtime? = Realtime() }
struct Realtime { var enabled = true }
enum AudioRoute { case speaker, bluetooth, isolated }
enum Haptics { static func play(_ value: Kind) {} ; enum Kind { case light } }
struct TTSSettingsView: View { var body: some View { Text("Synthetic voice settings") } }
struct VoiceCallAdvancedView: View { var body: some View { Text("Synthetic advanced settings") } }

@main struct FixtureApp: App {
    @State var dependencies = AppDependencyContainer()
    @State var preview = false
    init() {
        if ProcessInfo.processInfo.environment["RESET_VOICE_SETTINGS"] == "1" {
            UserDefaults.standard.removeObject(forKey: "voiceCall.thinkingSound")
            UserDefaults.standard.removeObject(forKey: "voiceCall.realtimeBridge")
        }
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VoiceCallSettingsView()
                    .toolbar { Button("Audio preview") { preview = true } }
            }
            .environment(dependencies)
            .sheet(isPresented: $preview) { PreviewView() }
        }
    }
}

@MainActor @Observable final class PreviewAudio {
    let engine = AVAudioEngine()
    let sound = CallThinkingSound()
    var state = "Listening"
    init() {
        engine.attach(sound.node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.connect(sound.node, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }
    func transition(_ next: String) {
        state = next
        sound.setActive(next == "Thinking")
    }
    func stop() { sound.setActive(false); engine.stop() }
}
struct PreviewView: View {
    @State var audio = PreviewAudio()
    var body: some View {
        VStack(spacing: 28) {
            Text("Thinking sound").font(.title.bold())
            Image(systemName: audio.state == "Thinking" ? "waveform" : "mic")
                .font(.system(size: 72)).foregroundStyle(.purple)
            Text(audio.state).font(.title2)
            ForEach(["Listening", "Thinking", "Speaking", "Paused", "Ended"], id: \.self) { name in
                Button(name) { audio.transition(name) }.buttonStyle(.bordered)
            }
            Text("Synthetic audio preview\nNo microphone or server used")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .onDisappear { audio.stop() }
    }
}
