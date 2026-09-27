import SwiftUI

@MainActor final class MockBackend {
    enum Outcome { case fail, empty, success, hold }
    struct Call { let data: Data; let local: Bool; let authorization: String?; let timeout: TimeInterval? }
    static let shared = MockBackend()
    var outcomes: [Outcome] = [.fail, .success]
    var calls: [Call] = []
    var delay: Duration = .zero
    var continuation: CheckedContinuation<String, Error>?
    func reset() { outcomes = [.fail, .success]; calls = []; delay = .zero; continuation = nil }
    func transcribe(_ data: Data, local: Bool, authorization: String? = nil, timeout: TimeInterval? = nil) async throws -> String {
        calls.append(Call(data: data, local: local, authorization: authorization, timeout: timeout))
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        if delay != .zero { try await Task.sleep(for: delay) }
        switch outcome {
        case .fail: throw NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection interrupted"])
        case .empty: return " \n "
        case .success: return "Fold the paper kite and attach a blue ribbon."
        case .hold: return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
}
@MainActor final class FakeNetwork { var authToken: String? = "synthetic-session" }
@MainActor final class APIClient {
    let network = FakeNetwork()
    func transcribeSpeech(audioData: Data, fileName: String, authorization: String? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        ["text": try await MockBackend.shared.transcribe(audioData, local: false, authorization: authorization, timeout: timeout)]
    }
}
@MainActor final class ServerSpeechRecognitionService {
    var apiClient: APIClient? = APIClient()
    var isAvailable: Bool { apiClient != nil }
}
@MainActor final class OnDeviceASRService {
    enum State { case unloaded, loading, ready, transcribing }
    var isAvailable = true
    var state: State = .unloaded
    func transcribe(audioData: Data, fileName: String) async throws -> String {
        try await MockBackend.shared.transcribe(audioData, local: true)
    }
}
enum Haptics { enum Kind { case medium }; static func play(_ kind: Kind) {} }
struct SyntheticTheme {
    var isDark = false
    var brandPrimary: Color { .blue }
    var surfaceContainer: Color { Color(uiColor: .secondarySystemBackground) }
    var textSecondary: Color { .secondary }
    var error: Color { .red }
    var cardBackground: Color { Color(uiColor: .secondarySystemBackground) }
    var inputBackground: Color { Color(uiColor: .secondarySystemBackground) }
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = SyntheticTheme() }
extension EnvironmentValues { var theme: SyntheticTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }
extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular) -> some View { font(.system(size: size, weight: weight)) }
}
