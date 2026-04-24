import SwiftUI

// MARK: - Automation Detail / Editor

struct AutomationDetailView: View {
    let automation: Automation
    @Bindable var listVM: AutomationsViewModel
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    // Editable state
    @State private var name: String
    @State private var prompt: String
    @State private var selectedSchedule: AutomationSchedule
    @State private var scheduleTime: Date   // hour+minute for daily/weekly/monthly/hourly
    @State private var scheduleDate: Date   // full date+time for once
    @State private var selectedWeekdays: Set<Int>
    @State private var scheduleMonthDay: Int
    @State private var customRRule: String
    @State private var selectedModelId: String

    // UI state
    @State private var runs: [AutomationRun] = []
    @State private var isLoadingRuns = false
    @State private var isSaving = false
    @State private var isRunning = false
    @State private var showDeleteConfirm = false
    @State private var showModelPicker = false
    @State private var hasChanges = false

    @Environment(\.theme) private var theme
    private var models: [AIModel] { dependencies.activeChatStore.cachedModels }

    init(automation: Automation, listVM: AutomationsViewModel) {
        self.automation = automation
        self._listVM = Bindable(listVM)
        _name = State(initialValue: automation.name)
        _prompt = State(initialValue: automation.data.prompt)
        let sched = AutomationSchedule.fromRRule(automation.data.rrule)
        _selectedSchedule = State(initialValue: sched)
        _selectedWeekdays = State(initialValue: AutomationSchedule.extractWeekdays(automation.data.rrule))
        _scheduleMonthDay = State(initialValue: AutomationSchedule.extractMonthDay(automation.data.rrule))
        _customRRule = State(initialValue: sched == .custom ? automation.data.rrule : "")
        _selectedModelId = State(initialValue: automation.data.modelId)

        let h = AutomationSchedule.extractHour(automation.data.rrule)
        let m = AutomationSchedule.extractMinute(automation.data.rrule)
        let timeDate = Calendar.current.date(from: DateComponents(hour: h, minute: m)) ?? Date()
        _scheduleTime = State(initialValue: timeDate)

        // For "once", prefer the full DTSTART date (includes year/month/day)
        if let dtDate = AutomationSchedule.extractDTSTARTDate(automation.data.rrule) {
            _scheduleDate = State(initialValue: dtDate)
        } else {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = h; comps.minute = m
            _scheduleDate = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        }
    }

    var currentRRule: String {
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

    var modelName: String {
        models.first(where: { $0.id == selectedModelId })?.name ?? selectedModelId
    }

    private var liveAutomation: Automation {
        listVM.automations.first(where: { $0.id == automation.id }) ?? automation
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    instructionsSection
                    configSection
                }
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(name.isEmpty ? "Automation" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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
        .confirmationDialog("Delete Automation", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await listVM.deleteAutomation(liveAutomation); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this automation and all its run history.")
        }
        .task { await loadRuns() }
        .onChange(of: name)            { _, _ in hasChanges = true }
        .onChange(of: prompt)          { _, _ in hasChanges = true }
        .onChange(of: selectedSchedule){ _, _ in hasChanges = true }
        .onChange(of: scheduleTime)    { _, _ in hasChanges = true }
        .onChange(of: scheduleDate)    { _, _ in hasChanges = true }
        .onChange(of: selectedWeekdays){ _, _ in hasChanges = true }
        .onChange(of: scheduleMonthDay){ _, _ in hasChanges = true }
        .onChange(of: selectedModelId) { _, _ in hasChanges = true }
        .onChange(of: customRRule)     { _, _ in hasChanges = true }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 20)
                .padding(.top, 16)

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
                    .frame(minHeight: 140)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Configuration

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")

            // --- Schedule card ---
            VStack(spacing: 0) {
                configRow("Repeats") {
                    Menu {
                        ForEach(AutomationSchedule.allCases, id: \.self) { sched in
                            Button { selectedSchedule = sched } label: {
                                Label(sched.rawValue, systemImage: sched.systemImage)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: selectedSchedule.systemImage)
                                .font(.system(size: 12))
                            Text(selectedSchedule.rawValue)
                                .scaledFont(size: 14)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(theme.accentColor)
                    }
                }

                // Once: compact date+time picker
                if selectedSchedule == .once {
                    rowDivider
                    configRow(nil) {
                        DatePicker("", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .tint(theme.accentColor)
                    }
                }

                // Daily / Weekly / Monthly: compact time picker
                if selectedSchedule == .daily || selectedSchedule == .weekly || selectedSchedule == .monthly {
                    rowDivider
                    configRow("Time") {
                        DatePicker("", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .tint(theme.accentColor)
                    }
                }

                // Weekly: day buttons
                if selectedSchedule == .weekly {
                    rowDivider
                    WeekdayPickerRow(selectedWeekdays: $selectedWeekdays)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                // Monthly: day-of-month menu picker
                if selectedSchedule == .monthly {
                    rowDivider
                    configRow("Day") {
                        Picker("", selection: $scheduleMonthDay) {
                            ForEach(1...31, id: \.self) { d in
                                Text("\(d)").tag(d)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(theme.accentColor)
                    }
                }

                // Hourly: minute menu picker
                if selectedSchedule == .hourly {
                    rowDivider
                    configRow("At minute") {
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
                        .tint(theme.accentColor)
                    }
                }

                // Custom RRULE
                if selectedSchedule == .custom {
                    rowDivider
                    configRow("RRULE") {
                        TextField("RRULE:FREQ=DAILY;...", text: $customRRule)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 2)

            // Model row
            configRowStandalone("Model") {
                Button { showModelPicker = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text(modelName)
                            .scaledFont(size: 14)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(theme.accentColor)
                }
            }

            // --- Status ---
            sectionHeader("Status")

            VStack(spacing: 0) {
                configRow("State") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(liveAutomation.isActive ? Color.green : theme.textTertiary)
                            .frame(width: 8, height: 8)
                        Text(liveAutomation.isActive ? "Active" : "Paused")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                if let nextRun = liveAutomation.nextRunAt {
                    rowDivider
                    configRow("Next run") {
                        HStack(spacing: 4) {
                            Text(nextRun, style: .date)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                            Text(nextRun, style: .time)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }

                rowDivider
                configRow("Last ran") {
                    if let lastRun = liveAutomation.lastRunAt {
                        Text(lastRun, style: .relative)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Text("Never")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // --- Execution Logs ---
            sectionHeader("Execution Logs")
            executionLogs
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var rowDivider: some View {
        Divider().opacity(0.25).padding(.leading, 16)
    }

    private var executionLogs: some View {
        VStack(spacing: 0) {
            if isLoadingRuns {
                ProgressView().padding()
            } else if runs.isEmpty {
                Text("No runs yet")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(runs.enumerated()), id: \.element.id) { idx, run in
                    HStack(spacing: 10) {
                        Image(systemName: run.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(run.isSuccess ? Color.green : Color.red)
                            .font(.system(size: 16))
                        Text(automation.name)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(run.createdAt, style: .relative)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    if idx < runs.count - 1 {
                        Divider().opacity(0.25).padding(.leading, 16)
                    }
                }
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Row Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(theme.textTertiary)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func configRow<T: View>(_ label: String?, @ViewBuilder trailing: () -> T) -> some View {
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

    @ViewBuilder
    private func configRowStandalone<T: View>(_ label: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 2)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isRunning {
                ProgressView().scaleEffect(0.8)
            } else {
                Button {
                    Task {
                        isRunning = true
                        await listVM.runNow(liveAutomation)
                        isRunning = false
                        await loadRuns()
                    }
                } label: {
                    Label("Run now", systemImage: "play.fill")
                        .scaledFont(size: 14, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView().scaleEffect(0.8)
            } else if hasChanges {
                Button("Save") {
                    Task {
                        isSaving = true
                        await listVM.updateAutomation(
                            id: automation.id,
                            name: name,
                            prompt: prompt,
                            modelId: selectedModelId,
                            rrule: currentRRule
                        )
                        isSaving = false
                        hasChanges = false
                    }
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Load Runs

    private func loadRuns() async {
        isLoadingRuns = true
        runs = (try? await listVM.fetchRuns(automationId: automation.id)) ?? []
        isLoadingRuns = false
    }
}
