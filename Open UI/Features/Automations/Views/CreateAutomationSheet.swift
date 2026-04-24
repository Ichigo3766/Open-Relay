import SwiftUI

// MARK: - Create Automation Sheet

struct CreateAutomationSheet: View {
    @Bindable var vm: AutomationsViewModel
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var selectedSchedule: AutomationSchedule = .daily
    @State private var scheduleTime: Date = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var scheduleDate: Date = Date()
    @State private var selectedWeekdays: Set<Int> = [1] // 0=Su,1=Mo,...,6=Sa
    @State private var scheduleMonthDay: Int = 1
    @State private var customRRule: String = ""
    @State private var selectedModelId: String = ""

    // UI state
    @State private var isCreating = false
    @State private var showModelPicker = false

    @Environment(\.theme) private var theme
    private var models: [AIModel] { dependencies.activeChatStore.cachedModels }

    private var currentRRule: String {
        if selectedSchedule == .custom { return customRRule }
        if selectedSchedule == .once {
            // Pass the full date so DTSTART is embedded correctly
            return selectedSchedule.toRRule(weekdays: selectedWeekdays, monthDay: scheduleMonthDay, date: scheduleDate)
        }
        let cal = Calendar.current
        let h = cal.component(.hour, from: scheduleTime)
        let m = cal.component(.minute, from: scheduleTime)
        return selectedSchedule.toRRule(hour: h, minute: m,
                                        weekdays: selectedWeekdays, monthDay: scheduleMonthDay)
    }

    private var modelName: String {
        models.first(where: { $0.id == selectedModelId })?.name ?? (selectedModelId.isEmpty ? "Select model" : selectedModelId)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedModelId.isEmpty &&
        !currentRRule.isEmpty &&
        (selectedSchedule != .weekly || !selectedWeekdays.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        titleField
                        instructionsField
                        scheduleCard
                        Spacer(minLength: 16)
                        modelPickerRow
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("New Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!canCreate)
                    }
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelSelectorSheet(
                    models: models,
                    selectedModelId: selectedModelId,
                    serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                    authToken: dependencies.apiClient?.network.authToken,
                    isAdmin: false,
                    pinnedModelIds: [],
                    onEdit: nil,
                    onTogglePin: nil,
                    onSelect: { model in selectedModelId = model.id }
                )
            }
        }
        .task {
            if selectedModelId.isEmpty,
               let currentId = dependencies.activeChatStore.cachedSelectedModelId {
                selectedModelId = currentId
            }
        }
    }

    // MARK: - Title Field

    private var titleField: some View {
        ZStack(alignment: .leading) {
            if name.isEmpty {
                Text("Automation title")
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            }
            TextField("", text: $name)
                .scaledFont(size: 22, weight: .bold)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }

    // MARK: - Instructions Field

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 20)

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Enter prompt here.")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Schedule Card

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            // Schedule type row
            scheduleRow("Schedule") {
                Menu {
                    ForEach(AutomationSchedule.allCases, id: \.self) { sched in
                        Button { selectedSchedule = sched } label: {
                            Label(sched.rawValue, systemImage: sched.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedSchedule.rawValue)
                            .scaledFont(size: 15)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.textPrimary)
                }
            }

            // Once: date + time in one compact picker
            if selectedSchedule == .once {
                Divider().opacity(0.25).padding(.leading, 16)
                scheduleRow(nil) {
                    DatePicker("", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(theme.accentColor)
                }
            }

            // Daily / Weekly / Monthly: compact time picker
            if selectedSchedule == .daily || selectedSchedule == .weekly || selectedSchedule == .monthly {
                Divider().opacity(0.25).padding(.leading, 16)
                scheduleRow("Time") {
                    DatePicker("", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(theme.accentColor)
                }
            }

            // Weekly: multi-select day buttons
            if selectedSchedule == .weekly {
                Divider().opacity(0.25).padding(.leading, 16)
                WeekdayPickerRow(selectedWeekdays: $selectedWeekdays)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            // Monthly: day-of-month menu picker
            if selectedSchedule == .monthly {
                Divider().opacity(0.25).padding(.leading, 16)
                scheduleRow("Day") {
                    Picker("", selection: $scheduleMonthDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.textPrimary)
                }
            }

            // Hourly: compact minute-only display
            if selectedSchedule == .hourly {
                Divider().opacity(0.25).padding(.leading, 16)
                scheduleRow("At minute") {
                    Picker("", selection: Binding(
                        get: { Calendar.current.component(.minute, from: scheduleTime) },
                        set: { newMin in
                            let h = Calendar.current.component(.hour, from: scheduleTime)
                            scheduleTime = Calendar.current.date(from: DateComponents(hour: h, minute: newMin)) ?? scheduleTime
                        }
                    )) {
                        ForEach(0..<60, id: \.self) { m in
                            Text(":\(String(format: "%02d", m))").tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.textPrimary)
                }
            }

            // Custom RRULE
            if selectedSchedule == .custom {
                Divider().opacity(0.25).padding(.leading, 16)
                scheduleRow("RRULE") {
                    TextField("RRULE:FREQ=DAILY;...", text: $customRRule)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func scheduleRow<T: View>(_ label: String?, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            if let label {
                Text(label)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Model Picker Row

    private var modelPickerRow: some View {
        HStack(spacing: 12) {
            // Schedule chip
            Menu {
                ForEach(AutomationSchedule.allCases, id: \.self) { sched in
                    Button { selectedSchedule = sched } label: {
                        Label(sched.rawValue, systemImage: sched.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                    Text(selectedSchedule.rawValue)
                        .scaledFont(size: 14)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(theme.textSecondary)
            }

            // Model chip
            Button { showModelPicker = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                    Text(modelName)
                        .scaledFont(size: 14)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button {
                guard canCreate else { return }
                Task { await create() }
            } label: {
                Text("Create")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(canCreate ? theme.accentColor : theme.textTertiary)
                    .clipShape(Capsule())
            }
            .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // MARK: - Create

    private func create() async {
        isCreating = true
        let result = await vm.createAutomation(
            name: name.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespaces),
            modelId: selectedModelId,
            rrule: currentRRule
        )
        isCreating = false
        if result != nil { dismiss() }
    }
}

// MARK: - Weekday Picker Row

struct WeekdayPickerRow: View {
    @Binding var selectedWeekdays: Set<Int>
    @Environment(\.theme) private var theme

    private let labels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let isSelected = selectedWeekdays.contains(index)
                Button {
                    if isSelected {
                        if selectedWeekdays.count > 1 { selectedWeekdays.remove(index) }
                    } else {
                        selectedWeekdays.insert(index)
                    }
                } label: {
                    Text(labels[index])
                        .scaledFont(size: 13, weight: isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? .white : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isSelected ? theme.accentColor : theme.surfaceContainerHighest)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
