import SwiftUI

struct CalendarManagementView: View {
    @Bindable var vm: CalendarViewModel
    let userId: String
    let isAdmin: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var editing: OWCalendar?
    @State private var deleting: OWCalendar?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.calendars) { calendar in
                    HStack {
                        Circle().fill(calendar.swiftUIColor).frame(width: 12, height: 12)
                        VStack(alignment: .leading) {
                            Text(calendar.name)
                            if calendar.isSystem { Text("System calendar").font(.caption).foregroundStyle(.secondary) }
                            else if calendar.userId != userId { Text("Shared calendar").font(.caption).foregroundStyle(.secondary) }
                            else if calendar.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !calendar.isSystem && (calendar.userId == userId || isAdmin) {
                            Menu {
                                Button("Edit", systemImage: "pencil") { editing = calendar }
                                if calendar.userId == userId && !calendar.isDefault {
                                    Button("Make Default", systemImage: "checkmark.circle") {
                                        Task {
                                            do { try await vm.makeDefaultCalendar(calendar, userId: userId) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                    }
                                }
                                if !calendar.isDefault {
                                    Button("Delete Calendar", systemImage: "trash", role: .destructive) { deleting = calendar }
                                }
                            } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("Actions for \(calendar.name)")
                        }
                    }
                }
            }
            .disabled(vm.isManagingCalendars)
            .navigationTitle("Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close").disabled(vm.isManagingCalendars)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Calendar").disabled(vm.isManagingCalendars)
                }
            }
            .sheet(isPresented: $creating) { CalendarEditor(vm: vm).themed() }
            .sheet(item: $editing) { CalendarEditor(vm: vm, calendar: $0).themed() }
            .confirmationDialog("Delete Calendar?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Calendar", role: .destructive) {
                    if let deleting {
                        Task {
                            do { try await vm.removeCalendar(deleting) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    deleting = nil
                }
            } message: { Text("This permanently deletes the calendar and all its events. This cannot be undone.") }
            .alert("Couldn’t update calendar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .interactiveDismissDisabled(vm.isManagingCalendars)
    }
}

private struct CalendarEditor: View {
    @Bindable var vm: CalendarViewModel
    var calendar: OWCalendar?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    @State private var colorChanged = false
    @State private var errorMessage: String?

    init(vm: CalendarViewModel, calendar: OWCalendar? = nil) {
        self.vm = vm
        self.calendar = calendar
        _name = State(initialValue: calendar?.name ?? "")
        _color = State(initialValue: calendar?.swiftUIColor ?? Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                ColorPicker("Color", selection: Binding(get: { color }, set: { color = $0; colorChanged = true }), supportsOpacity: false)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(vm.isManagingCalendars)
            .navigationTitle(calendar == nil ? "New Calendar" : "Edit Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel").disabled(vm.isManagingCalendars)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            var hex: String?
                            if calendar == nil || colorChanged {
                                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                                hex = String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
                            }
                            do { try await vm.saveCalendar(calendar, name: name, color: hex); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        if vm.isManagingCalendars { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .accessibilityLabel("Save").disabled(vm.isManagingCalendars || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(vm.isManagingCalendars)
    }
}
