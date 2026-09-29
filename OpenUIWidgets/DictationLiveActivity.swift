import ActivityKit
import SwiftUI
import WidgetKit

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 14) {
                DictationActivityIcon(isStale: context.isStale)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.red.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.isStale ? "Check recording" : "Recording")
                        .font(.headline)
                    Text(context.isStale ? "Open Open Relay to check" : "Microphone dictation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DictationActivityTimer(context: context)
                    .font(.title2.weight(.medium))
                    .frame(width: 96)
                    .minimumScaleFactor(0.75)
            }
            .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale ? "Check recording" : "Recording",
                          systemImage: context.isStale ? "mic.slash.fill" : "mic.fill")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DictationActivityTimer(context: context)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open Open Relay to check" : "Microphone dictation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                DictationActivityIcon(isStale: context.isStale)
            } compactTrailing: {
                DictationActivityTimer(context: context)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                DictationActivityIcon(isStale: context.isStale)
            }
            .keylineTint(.red)
        }
    }
}

private struct DictationActivityIcon: View {
    let isStale: Bool

    var body: some View {
        Image(systemName: isStale ? "mic.slash.fill" : "mic.fill")
            .foregroundStyle(isStale ? Color.secondary : Color.red)
            .accessibilityLabel(isStale ? "Check recording" : "Recording")
    }
}

private struct DictationActivityTimer: View {
    let context: ActivityViewContext<DictationActivityAttributes>

    var body: some View {
        // Bound the native timer even if iOS delays redrawing the stale presentation.
        Text(timerInterval: context.attributes.startDate...max(context.attributes.startDate, context.state.expiresAt),
             pauseTime: context.isStale ? context.state.confirmedAt : nil,
             countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}
