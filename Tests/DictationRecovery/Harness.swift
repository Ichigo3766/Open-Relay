import SwiftUI

@MainActor @Observable final class Demo {
    var draft = "Plan a paper-kite workshop."
    let context = DictationContext(server: "https://example.invalid", account: "fixture", conversation: "workshop")
    let service: DictationService
    init() {
        let store = DictationRecoveryStore(directory: URL.applicationSupportDirectory.appendingPathComponent("RecoveryDemo"))
        service = DictationService(recoveryStore: store)
        service.serverSpeechService = ServerSpeechRecognitionService()
        service.onDeviceASRService = OnDeviceASRService()
        MockBackend.shared.reset()
        MockBackend.shared.delay = .seconds(2)
        if let entry = try? store.load(context) { draft = entry.draft }
        service.bind(to: context, isCurrent: { true }, draft: { [weak self] in self?.draft },
                     deliver: { [weak self] in self?.draft = $0 })
    }
    func record() {
        do {
            draft = "Plan a paper-kite workshop."
            let audio = try Data(contentsOf: Bundle.main.url(forResource: "five-minute", withExtension: "m4a")!)
            _ = try service.qaRecord(audio)
        } catch { draft = "Fixture error: " + error.localizedDescription }
    }
}

struct RecoveryDemo: View {
    @State private var demo = Demo()
    private let isLight = ProcessInfo.processInfo.arguments.contains("--light-mode")
    var body: some View {
        VStack(spacing: 20) {
            Text("Dictation recovery").font(.title2.bold()).padding(.horizontal)
            Text("Synthetic five-minute audio · No microphone or server")
                .font(.caption).foregroundStyle(.secondary)
            Text(demo.draft).padding().accessibilityIdentifier("draft")
            Button("Record synthetic audio") { demo.record() }
                .disabled(demo.service.pendingRecording != nil)
            Spacer()
            if demo.service.isActive || demo.service.showsRecovery {
                DictationOverlayView(service: demo.service, onStop: { demo.service.stopDictation() },
                                     onCancel: { demo.service.cancelDictation() })
            }
        }
        .padding(.vertical)
        .environment(\.theme, SyntheticTheme(isDark: !isLight))
        .preferredColorScheme(isLight ? .light : .dark)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-type") ? .accessibility3 : .large)
    }
}

@main struct RecoveryQAApp: App { var body: some Scene { WindowGroup { RecoveryDemo() } } }
