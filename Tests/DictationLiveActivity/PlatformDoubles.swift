import ActivityKit
import Foundation
import Observation

// Compile the unmodified production service/controller with deterministic platform doubles.
// No permissions, microphone capture, server requests, or personal data are involved.
@MainActor enum ActivityStorage {
    static var values: [Any] = []
    static var enabled = true
    static var fails = false
}
@MainActor struct ActivityAuthorizationInfo {
    var areActivitiesEnabled: Bool { ActivityStorage.enabled }
}
@MainActor final class Activity<A: ActivityAttributes> {
    let attributes: A
    var updates: [ActivityContent<A.ContentState>]
    var ended = false
    init(_ attributes: A, _ content: ActivityContent<A.ContentState>) {
        self.attributes = attributes
        updates = [content]
    }
    static var activities: [Activity<A>] { ActivityStorage.values.compactMap { $0 as? Activity<A> }.filter { !$0.ended } }
    static func request(attributes: A, content: ActivityContent<A.ContentState>, pushType: String?) throws -> Activity<A> {
        if ActivityStorage.fails { throw CocoaError(.featureUnsupported) }
        let activity = Activity(attributes, content)
        ActivityStorage.values.append(activity)
        return activity
    }
    func update(_ content: ActivityContent<A.ContentState>) async { if !ended { updates.append(content) } }
    func end(_ content: ActivityContent<A.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async { ended = true }
}

@MainActor enum AVAudioApplication {
    static var allowed = true
    static func requestRecordPermission() async -> Bool { allowed }
}
@MainActor final class AVAudioSession {
    enum Category { case playAndRecord }
    enum Mode { case measurement }
    struct Options: OptionSet {
        let rawValue: Int
        static let defaultToSpeaker = Options(rawValue: 1)
        static let allowBluetoothA2DP = Options(rawValue: 2)
        static let notifyOthersOnDeactivation = Options(rawValue: 4)
    }
    enum InterruptionType: UInt { case ended = 0, began = 1 }
    nonisolated static let interruptionNotification = Notification.Name("SyntheticAudioInterruption")
    nonisolated static let mediaServicesWereResetNotification = Notification.Name("SyntheticAudioReset")
    static let shared = AVAudioSession()
    static var fails = false
    static func sharedInstance() -> AVAudioSession { shared }
    func requestRecordPermission(_ result: (Bool) -> Void) { result(AVAudioApplication.allowed) }
    func setCategory(_ category: Category, mode: Mode, options: Options) throws {
        if Self.fails { throw CocoaError(.featureUnsupported) }
    }
    func setActive(_ active: Bool, options: Options) throws {}
}
protocol AVAudioRecorderDelegate: NSObjectProtocol {}
@MainActor final class AVAudioRecorder {
    static var latest: AVAudioRecorder?
    static var starts = true
    static var prepares = true
    let url: URL
    var delegate: AVAudioRecorderDelegate?
    var isMeteringEnabled = false
    var isRecording = false
    var currentTime: TimeInterval = 301
    init(url: URL, settings: [String: Any]) throws { self.url = url; Self.latest = self }
    func prepareToRecord() -> Bool {
        try! Data("Synthetic audio bytes".utf8).write(to: url)
        return Self.prepares
    }
    func record() -> Bool { isRecording = Self.starts; return isRecording }
    func stop() { isRecording = false }
    func updateMeters() {}
    func averagePower(forChannel: Int) -> Float { -60 }
}
@MainActor final class APIClient {
    final class Network { var authToken: String? = "synthetic-token" }
    let network = Network()
    var calls = 0
    var response: (() async throws -> [String: Any])?
    func transcribeSpeech(audioData: Data, fileName: String, authorization: String?, timeout: TimeInterval) async throws -> [String: Any] {
        calls += 1
        if let response { return try await response() }
        throw CocoaError(.fileReadUnknown)
    }
}
@MainActor final class ServerSpeechRecognitionService {
    var apiClient: APIClient? = APIClient()
    var isAvailable = true
}
@MainActor final class OnDeviceASRService {
    enum State { case loading, transcribing, ready }
    var state = State.ready
    var isAvailable = true
    var response: (() async throws -> String)?
    func transcribe(audioData: Data, fileName: String) async throws -> String {
        if let response { return try await response() }
        throw CocoaError(.fileReadUnknown)
    }
}

enum ASRError: Error { case backgroundInterrupted }
struct UIBackgroundTaskIdentifier: Hashable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    nonisolated static let didEnterBackgroundNotification = Notification.Name("SyntheticBackground")
    nonisolated static let didBecomeActiveNotification = Notification.Name("SyntheticActive")
    var applicationState = State.active
    var grantsTime = true
    var started = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    var tasks: [UIBackgroundTaskIdentifier: () -> Void] = [:]
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        guard grantsTime else { return .invalid }
        started += 1
        let id = UIBackgroundTaskIdentifier(rawValue: started)
        tasks[id] = expirationHandler
        return id
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        ended.append(id)
        tasks.removeValue(forKey: id)
    }
    func transition(to state: State) {
        applicationState = state
        NotificationCenter.default.post(name: state == .active ? Self.didBecomeActiveNotification : Self.didEnterBackgroundNotification, object: nil)
    }
}
