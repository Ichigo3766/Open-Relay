import SwiftUI

/// Responses are confirmed by the server before changing the displayed status.
struct CalendarRSVPView: View {
    let event: CalendarEvent
    @Bindable var vm: CalendarViewModel
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var errorMessage: String?

    private var currentEvent: CalendarEvent {
        vm.events.first { $0.id == event.id && $0.instanceId == event.instanceId } ?? event
    }

    var body: some View {
        if !event.isCancelled, !event.isAutomationEvent, !event.isRunEvent,
           let userId = dependencies.authViewModel.currentUser?.id,
           let attendee = currentEvent.attendees.first(where: { $0.userId == userId }) {
            Divider().background(theme.divider).padding(.leading, 56)
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 18))
                    .frame(width: 24)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Response").font(.caption).foregroundStyle(theme.textTertiary)
                    Menu {
                        ForEach(CalendarRSVP.allCases, id: \.rawValue) { response in
                            Button {
                                Task {
                                    do {
                                        try await vm.respondToEvent(currentEvent, userId: userId, response: response)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                if attendee.status == response.rawValue {
                                    Label(response.label, systemImage: "checkmark")
                                } else {
                                    Text(response.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(CalendarRSVP(rawValue: attendee.status)?.label ?? attendee.status)
                            if vm.respondingEventIds.contains(event.id) {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(vm.respondingEventIds.contains(event.id))
                    .accessibilityLabel("Your Response")
                    .accessibilityValue(CalendarRSVP(rawValue: attendee.status)?.label ?? attendee.status)
                    if event.rrule != nil {
                        Text("Applies to the entire series.")
                            .font(.caption).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .alert("Couldn’t save response", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
