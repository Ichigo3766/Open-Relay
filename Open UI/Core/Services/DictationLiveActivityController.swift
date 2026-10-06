import ActivityKit
import Foundation
import os.log

@MainActor
final class DictationLiveActivityController {
    private var activity: Activity<DictationActivityAttributes>?
    private var lastConfirmation = Date.distantPast

    init() {
        // Snapshot before scheduling cleanup, so it cannot end a new recording.
        let previous = Activity<DictationActivityAttributes>.activities
        Task {
            for activity in previous {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(at date: Date = .now) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: DictationActivityAttributes(startDate: date),
                                            content: content(at: date), pushType: nil)
            lastConfirmation = date
        } catch {
            // Recording must still work if the system cannot present an activity.
            Logger(subsystem: "com.openui", category: "DictationLiveActivity")
                .error("Unable to start dictation Live Activity")
        }
    }

    /// The system draws the timer. Only confirm occasionally that capture is still alive.
    func confirmRecording(at date: Date = .now) {
        guard let activity, date.timeIntervalSince(lastConfirmation) >= 30 else { return }
        lastConfirmation = date
        let content = content(at: date)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func content(at date: Date) -> ActivityContent<DictationActivityAttributes.ContentState> {
        let state = DictationActivityAttributes.ContentState(confirmedAt: date)
        return ActivityContent(state: state, staleDate: state.expiresAt)
    }
}
