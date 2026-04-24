import SwiftUI

struct CalendarEventDetailView: View {
    let event: CalendarEvent
    @Bindable var vm: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var showDeleteConfirm = false

    private var calendarName: String {
        vm.calendars.first(where: { $0.id == event.calendarId })?.name ?? "Calendar"
    }

    private var calendarColor: Color {
        vm.color(for: event.calendarId)
    }

    private var timeString: String {
        if event.allDay { return "All day" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        if let end = event.endAt {
            let startStr = fmt.string(from: event.startAt)
            // Same day: just show times
            let cal = Calendar.current
            if cal.isDate(event.startAt, inSameDayAs: end) {
                let timeFmt = DateFormatter()
                timeFmt.dateFormat = "h:mm a"
                return "\(startStr) – \(timeFmt.string(from: end))"
            }
            return "\(startStr) – \(fmt.string(from: end))"
        }
        return fmt.string(from: event.startAt)
    }

    private var reminderLabel: String {
        guard let mins = event.meta?.alertMinutes else { return "" }
        switch mins {
        case 0: return "At time of event"
        case 5: return "5 minutes before"
        case 10: return "10 minutes before"
        case 15: return "15 minutes before"
        case 30: return "30 minutes before"
        case 60: return "1 hour before"
        default: return "\(mins) minutes before"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header: title + calendar color strip
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(calendarColor)
                                .frame(width: 4)
                                .frame(maxHeight: .infinity)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary)

                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(calendarColor)
                                        .frame(width: 8, height: 8)
                                    Text(calendarName)
                                        .font(.subheadline)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 16)

                        Divider().background(theme.divider)

                        // Date/Time
                        detailRow(icon: "clock", title: "When", value: timeString)

                        if event.rrule != nil {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "repeat", title: "Recurrence", value: event.rrule ?? "")
                        }

                        if let loc = event.location, !loc.isEmpty {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "mappin", title: "Location", value: loc)
                        }

                        if let desc = event.description, !desc.isEmpty {
                            Divider().background(theme.divider).padding(.leading, 56)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 16) {
                                    Image(systemName: "doc.text")
                                        .frame(width: 24)
                                        .foregroundStyle(theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Description")
                                            .font(.caption)
                                            .foregroundStyle(theme.textTertiary)
                                        Text(desc)
                                            .font(.body)
                                            .foregroundStyle(theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            }
                        }

                        if !reminderLabel.isEmpty {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "bell", title: "Reminder", value: reminderLabel)
                        }

                        // Automation run status
                        if event.isRunEvent, let status = event.meta?.status {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(
                                icon: status == "success" ? "checkmark.circle.fill" : "xmark.circle.fill",
                                title: "Run Status",
                                value: status == "success" ? "Succeeded" : "Failed",
                                valueColor: status == "success" ? .green : .red
                            )
                        }

                        // Delete button (only for non-system, non-run events)
                        if !event.isRunEvent {
                            Divider()
                                .background(theme.divider)
                                .padding(.top, 20)

                            Button {
                                showDeleteConfirm = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("Delete Event", systemImage: "trash")
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .confirmationDialog(
                "Delete \"\(event.title)\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Event", role: .destructive) {
                    Task {
                        await vm.deleteEvent(event)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This event will be permanently deleted.")
            }
        }
    }

    @ViewBuilder
    private func detailRow(
        icon: String,
        title: String,
        value: String,
        valueColor: Color? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(valueColor ?? theme.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
