import ActivityKit
import SwiftUI

/// Synthetic presentation harness: never opens a microphone or makes a network request.
@main struct DictationActivityQA: App {
    private let controller = DictationLiveActivityController()
    @State private var started = false
    @State private var staleScheduled = false
    @State private var updateCount = 0

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Synthetic dictation activity").font(.title2)
                    Text("No microphone or server is used.").foregroundStyle(.secondary)
                    Button("Start five-minute sample") {
                        controller.start(at: .now.addingTimeInterval(-300))
                        controller.confirmRecording()
                        started = true
                        staleScheduled = false
                    }
                    Button("Stop sample") { controller.end(); started = false }
                    Text(started ? "Sample active" : "Sample stopped")
                    if staleScheduled { Text("Stale sample scheduled") }
                    Text("Updated activities: \(updateCount)")
                    Button("Make sample stale") {
                        Task {
                            let activities = Activity<DictationActivityAttributes>.activities
                            for activity in activities {
                                await activity.update(ActivityContent(
                                    state: .init(confirmedAt: .now.addingTimeInterval(-87)), staleDate: .now.addingTimeInterval(3)))
                            }
                            updateCount = activities.count
                            staleScheduled = true
                        }
                    }
                }
                .padding()
                .buttonStyle(.borderedProminent)
                .navigationTitle("Recording preview")
            }
        }
    }
}
