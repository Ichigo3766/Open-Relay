import SwiftUI

struct CreateCalendarEventSheet: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalendarEventDraft
    @State private var repeatPreset: String
    @State private var isSaving = false
    @State private var saveError: String?
    private let isSeries: Bool

    private static let repeats = [
        ("Never", ""), ("Daily", "FREQ=DAILY"),
        ("Weekdays", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"),
        ("Weekly", "FREQ=WEEKLY"), ("Monthly", "FREQ=MONTHLY"), ("Yearly", "FREQ=YEARLY")
    ]
    private static let reminders = [
        ("None", -1), ("At time of event", 0), ("5 minutes before", 5),
        ("10 minutes before", 10), ("15 minutes before", 15), ("30 minutes before", 30), ("1 hour before", 60)
    ]

    init(vm: CalendarViewModel, event: CalendarEvent? = nil) {
        self.vm = vm
        isSeries = !(event?.rrule ?? "").isEmpty
        let hour = Calendar.current.dateInterval(of: .hour, for: vm.selectedDate)?.end ?? vm.selectedDate
        let draft = CalendarEventDraft(event: event,
            calendarID: vm.defaultCalendarId ?? vm.editableCalendars.first?.id ?? "", start: hour)
        _draft = State(initialValue: draft)
        _repeatPreset = State(initialValue: Self.repeats.first { $0.1 == draft.recurrence }?.0 ?? "Custom")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(vm.editableCalendars) { Text($0.name).tag($0.id) }
                    }
                }
                Section("When") {
                    Toggle("All day", isOn: $draft.allDay)
                    DatePicker("Starts", selection: $draft.start,
                        displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("End date", isOn: Binding(get: { draft.end != nil }, set: {
                        draft.end = $0 ? draft.start.addingTimeInterval(3600) : nil
                    }))
                    if draft.end != nil {
                        DatePicker("Ends", selection: Binding(get: { draft.end ?? draft.start }, set: { draft.end = $0 }),
                            displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    }
                }
                Section {
                    Picker("Repeat", selection: $repeatPreset) {
                        ForEach(Self.repeats, id: \.0) { Text($0.0).tag($0.0) }
                        Text("Custom").tag("Custom")
                    }
                    .onChange(of: repeatPreset) { _, value in
                        if let rule = Self.repeats.first(where: { $0.0 == value })?.1 { draft.recurrence = rule }
                    }
                    if repeatPreset == "Custom" {
                        TextField("Recurrence rule", text: $draft.recurrence)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    Picker("Reminder", selection: $draft.alertMinutes) {
                        ForEach(Self.reminders, id: \.1) { Text($0.0).tag($0.1) }
                        if !Self.reminders.contains(where: { $0.1 == draft.alertMinutes }) {
                            Text(draft.alertMinutes < 0 ? "None" : "\(draft.alertMinutes) minutes before").tag(draft.alertMinutes)
                        }
                    }
                } footer: {
                    if isSeries {
                        Text("Changes apply to the entire recurring series.")
                    }
                }
                Section {
                    TextField("Location", text: $draft.location)
                    TextField("Description", text: $draft.description, axis: .vertical).lineLimit(3...6)
                }
            }
            .disabled(isSaving)
            .navigationTitle(draft.id == nil ? "New Event" : (isSeries ? "Edit Series" : "Edit Event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel").disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .accessibilityLabel("Save").disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .alert("Couldn’t save event", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do { try await vm.saveEvent(draft); dismiss() }
        catch { saveError = error.localizedDescription }
    }
}
