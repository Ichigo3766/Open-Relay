import SwiftUI

struct CreateCalendarEventSheet: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // Form fields
    @State private var title = ""
    @State private var selectedCalendarId: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(3600)
    @State private var allDay = false
    @State private var location = ""
    @State private var description = ""
    @State private var alertMinutes: Int? = 10
    @State private var showAlertPicker = false
    @State private var isSaving = false

    // Reminder options matching the screenshot
    private let reminderOptions: [(label: String, minutes: Int?)] = [
        ("None", nil),
        ("At time of event", 0),
        ("5 minutes before", 5),
        ("10 minutes before", 10),
        ("15 minutes before", 15),
        ("30 minutes before", 30),
        ("1 hour before", 60)
    ]

    private var reminderLabel: String {
        reminderOptions.first(where: { $0.minutes == alertMinutes })?.label ?? "None"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Title
                        TextField("Title", text: $title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)

                        Divider().background(theme.divider)

                        // Calendar picker
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calendar")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            Picker("Calendar", selection: $selectedCalendarId) {
                                ForEach(vm.editableCalendars) { cal in
                                    HStack {
                                        Circle()
                                            .fill(cal.swiftUIColor)
                                            .frame(width: 10, height: 10)
                                        Text(cal.name)
                                    }
                                    .tag(cal.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                        }

                        Divider().background(theme.divider)

                        // When
                        VStack(alignment: .leading, spacing: 4) {
                            Text("When")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            HStack {
                                if allDay {
                                    DatePicker("", selection: $startDate, displayedComponents: .date)
                                        .labelsHidden()
                                    Text("–")
                                        .foregroundStyle(theme.textTertiary)
                                    DatePicker("", selection: $endDate, displayedComponents: .date)
                                        .labelsHidden()
                                } else {
                                    DatePicker("", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                    Text("–")
                                        .foregroundStyle(theme.textTertiary)
                                    DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                }

                                Spacer()

                                Toggle("All day", isOn: $allDay)
                                    .labelsHidden()
                                    .onChange(of: allDay) { _, newVal in
                                        if newVal {
                                            // Snap to midnight
                                            let cal = Calendar.current
                                            startDate = cal.startOfDay(for: startDate)
                                            endDate = cal.startOfDay(for: endDate)
                                        }
                                    }

                                Text("All day")
                                    .font(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                        }

                        Divider().background(theme.divider)

                        // Location
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Location")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            TextField("Add location", text: $location)
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                        }

                        Divider().background(theme.divider)

                        // Reminder
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reminder")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAlertPicker.toggle()
                                }
                            } label: {
                                HStack {
                                    Text(reminderLabel)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(theme.textTertiary)
                                        .rotationEffect(.degrees(showAlertPicker ? 180 : 0))
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                            }
                            .buttonStyle(.plain)

                            if showAlertPicker {
                                VStack(spacing: 0) {
                                    ForEach(reminderOptions, id: \.label) { option in
                                        Button {
                                            alertMinutes = option.minutes
                                            withAnimation { showAlertPicker = false }
                                        } label: {
                                            HStack {
                                                Text(option.label)
                                                    .foregroundStyle(theme.textPrimary)
                                                Spacer()
                                                if alertMinutes == option.minutes {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(theme.brandPrimary)
                                                        .font(.caption.weight(.semibold))
                                                }
                                            }
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.plain)

                                        if option.label != reminderOptions.last?.label {
                                            Divider()
                                                .background(theme.divider)
                                                .padding(.horizontal, 20)
                                        }
                                    }
                                }
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            }
                        }

                        Divider().background(theme.divider)

                        // Description
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            TextField("Add description", text: $description, axis: .vertical)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(3...6)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle(title.isEmpty ? "New Event" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await save() }
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(title.isEmpty ? theme.textTertiary : theme.brandPrimary)
                        .disabled(title.isEmpty)
                    }
                }
            }
        }
        .onAppear {
            // Default to the default calendar
            if selectedCalendarId.isEmpty {
                selectedCalendarId = vm.defaultCalendarId ?? vm.editableCalendars.first?.id ?? ""
            }
            // Default start/end based on selected date
            if let rounded = roundToNextHour(vm.selectedDate) {
                startDate = rounded
                endDate = rounded.addingTimeInterval(3600)
            }
        }
    }

    private func save() async {
        guard !title.isEmpty else { return }
        isSaving = true
        await vm.createEvent(
            calendarId: selectedCalendarId,
            title: title,
            description: description.isEmpty ? nil : description,
            startAt: startDate,
            endAt: allDay ? nil : endDate,
            allDay: allDay,
            location: location.isEmpty ? nil : location,
            alertMinutes: alertMinutes
        )
        isSaving = false
        dismiss()
    }

    private func roundToNextHour(_ date: Date) -> Date? {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        comps.minute = 0
        comps.second = 0
        if let base = cal.date(from: comps) {
            return cal.date(byAdding: .hour, value: 1, to: base)
        }
        return nil
    }
}
