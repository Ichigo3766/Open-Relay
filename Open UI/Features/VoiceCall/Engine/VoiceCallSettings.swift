import Foundation

/// Echo protection strength for barge-in (how much louder than the AI's own
/// echo the user must be to count).
enum EchoProtection: String, CaseIterable, Sendable {
    case normal, strong

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .strong: return "Strong"
        }
    }

    /// Multiplier on the sensitivity preset's echo margin.
    var marginMultiplier: Float { self == .strong ? 1.5 : 1.0 }
}

/// Centralised settings for the voice call feature, stored under `voiceCall.*` keys.
///
/// The call's **voice** is not stored here: calls speak with the same engine,
/// voice and speed as Read Aloud (`TextToSpeechService`), so there's one place
/// to choose the assistant's voice. `migrateLegacyKeysIfNeeded()` carries old
/// preferences over once. Called from `DependencyContainer.init`.
@MainActor @Observable
final class VoiceCallSettings {

    /// Bumped on every write so SwiftUI observes UserDefaults-backed properties.
    var revision = 0
    let defaults = UserDefaults.standard

    var useRealtimeBridge: Bool {
        get { bool("voiceCall.realtimeBridge", default: false) }
        set { set(newValue, "voiceCall.realtimeBridge") }
    }

    // MARK: - Listening

    /// Which speech-recognition engine to use during calls.
    /// Values: "apple" | "server" | "qwen3" | "parakeet"
    var sttEngine: String {
        get { _ = revision; return defaults.string(forKey: Keys.sttEngine) ?? "apple" }
        set { defaults.set(newValue, forKey: Keys.sttEngine); revision += 1 }
    }

    // MARK: - Turn-taking

    /// Voice-detection sensitivity preset (speech in noise).
    var vadSensitivity: VADSensitivity {
        get { _ = revision; return VADSensitivity(rawValue: defaults.string(forKey: Keys.vadSensitivity) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Keys.vadSensitivity); revision += 1 }
    }

    /// How long the user may pause before their turn ends.
    var turnPace: TurnPace {
        get { _ = revision; return TurnPace(rawValue: defaults.string(forKey: Keys.turnPace) ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: Keys.turnPace); revision += 1 }
    }

    /// Whether the user can interrupt the AI by speaking.
    var bargeInEnabled: Bool {
        get { bool(Keys.bargeInEnabled, default: true) }
        set { set(newValue, Keys.bargeInEnabled) }
    }

    /// Whether the loudspeaker is on by default when a call starts.
    var defaultSpeakerOn: Bool {
        get { bool(Keys.defaultSpeakerOn, default: true) }
        set { set(newValue, Keys.defaultSpeakerOn) }
    }

    /// A quiet loop while a call waits for its reply. Off unless opted in.
    var thinkingSoundEnabled: Bool {
        get { bool("voiceCall.thinkingSound", default: false) }
        set { set(newValue, "voiceCall.thinkingSound") }
    }

    // MARK: - Advanced

    /// Neural voice detection (Silero). Off: turns end on silence by mic
    /// level, and interrupting by speaking is unavailable.
    var vadEnabled: Bool {
        get { bool(Keys.vadEnabled, default: true) }
        set { set(newValue, Keys.vadEnabled) }
    }

    /// Smart Turn end-of-turn model. Off: only the pause length decides.
    var smartTurnEnabled: Bool {
        get { bool(Keys.smartTurnEnabled, default: true) }
        set { set(newValue, Keys.smartTurnEnabled) }
    }

    /// Use `customMinPause` / `customMaxPause` instead of the pace preset.
    var customPauseEnabled: Bool {
        get { bool(Keys.customPauseEnabled, default: false) }
        set { set(newValue, Keys.customPauseEnabled) }
    }

    static let minPauseRange: ClosedRange<Double> = 0.2...1.5
    static let maxPauseRange: ClosedRange<Double> = 1.0...8.0

    /// Shortest pause that can end a turn (seconds).
    var customMinPause: Double {
        get { double(Keys.customMinPause, default: TurnPace.balanced.minPause, in: Self.minPauseRange) }
        set { set(newValue.clamped(to: Self.minPauseRange), Keys.customMinPause) }
    }

    /// Longest pause before a turn always ends (seconds).
    var customMaxPause: Double {
        get { double(Keys.customMaxPause, default: TurnPace.balanced.maxPause, in: Self.maxPauseRange) }
        set { set(newValue.clamped(to: Self.maxPauseRange), Keys.customMaxPause) }
    }
}
