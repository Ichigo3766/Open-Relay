import SwiftUI
import UIKit

// MARK: - CalendarView (Sheet Root)

struct CalendarView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: CalendarViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                CalendarContentView(vm: vm, onDismiss: { dismiss() })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Prevent sheet's swipe-to-dismiss from stealing UICalendarView's horizontal swipe
        .interactiveDismissDisabled()
        .task {
            if viewModel == nil, let api = dependencies.apiClient {
                let vm = CalendarViewModel(apiClient: api)
                viewModel = vm
                await vm.load()
            }
        }
    }
}

// MARK: - Main Content

private struct CalendarContentView: View {
    @Bindable var vm: CalendarViewModel
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    // Pinch gesture tracking
    @State private var pinchScale: CGFloat = 1.0
    @State private var pinchActive: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Custom top bar ──────────────────────────────
            topBar

            Divider()
                .background(theme.divider)

            // ── Mode-specific content ───────────────────────
            ZStack {
                switch vm.viewMode {
                case .year:
                    YearView(vm: vm)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 1.15).combined(with: .opacity)
                        ))
                case .month:
                    MonthView(vm: vm)
                        .transition(.asymmetric(
                            insertion: vm.viewMode == .month
                                ? .scale(scale: 0.85).combined(with: .opacity)
                                : .scale(scale: 1.15).combined(with: .opacity),
                            removal: .opacity
                        ))
                case .week:
                    WeekView(vm: vm)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 1.15).combined(with: .opacity)
                        ))
                case .day:
                    DayView(vm: vm)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 1.15).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: vm.viewMode)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !pinchActive {
                            pinchActive = true
                        }
                        pinchScale = value
                    }
                    .onEnded { value in
                        pinchActive = false
                        pinchScale = 1.0
                        if value < 0.82 {
                            // Pinch in → zoom out to broader view
                            vm.zoomOut()
                        } else if value > 1.22 {
                            // Pinch out → zoom in to finer view
                            vm.zoomIn()
                        }
                    }
            )
        }
        .background(theme.background.ignoresSafeArea())
        .sheet(isPresented: $vm.showCreateEvent) {
            CreateCalendarEventSheet(vm: vm)
        }
        .sheet(item: $vm.selectedEvent) { event in
            CalendarEventDetailView(event: event, vm: vm)
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // Close button
            Button { onDismiss() } label: {
                ZStack {
                    Circle()
                        .fill(theme.surfaceContainer)
                        .frame(width: 32, height: 32)
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(topBarTitle)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .animation(.none, value: vm.viewMode)

            Spacer()

            HStack(spacing: 10) {
                // Today button
                Button {
                    vm.goToToday()
                } label: {
                    Text("Today")
                        .font(.subheadline)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)

                // View mode picker
                Menu {
                    ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                vm.viewMode = mode
                            }
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if vm.viewMode == mode {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.viewMode.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.surfaceContainer, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)

                // New event
                Button {
                    vm.showCreateEvent = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.editableCalendars.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var topBarTitle: String {
        switch vm.viewMode {
        case .year:  return vm.yearTitle
        case .month: return vm.monthTitle
        case .week:
            let cal = Calendar.current
            let days = vm.currentWeekDays
            guard let first = days.first, let last = days.last else { return "Calendar" }
            let firstComps = cal.dateComponents([.year, .month], from: first)
            let lastComps  = cal.dateComponents([.year, .month], from: last)
            let fmt = DateFormatter()
            if firstComps.month == lastComps.month {
                fmt.dateFormat = "MMMM yyyy"
                return fmt.string(from: first)
            } else {
                let m1 = DateFormatter(); m1.dateFormat = "MMM"
                let m2 = DateFormatter(); m2.dateFormat = "MMM yyyy"
                return "\(m1.string(from: first)) – \(m2.string(from: last))"
            }
        case .day:
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE, MMMM d"
            return fmt.string(from: vm.selectedDate)
        }
    }
}

// MARK: - Year View

private struct YearView: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // Year navigation header
                HStack {
                    Button {
                        navigateYear(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(vm.yearTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)

                    Spacer()

                    Button {
                        navigateYear(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(vm.currentYearMonths, id: \.self) { month in
                        MiniMonthView(month: month, vm: vm)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    vm.displayedMonth = month
                                    vm.viewMode = .month
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task {
            // Load a full year of events
            let cal = Calendar.current
            let year = cal.component(.year, from: vm.displayedMonth)
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? vm.displayedMonth
            let end   = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? vm.displayedMonth
            await vm.loadEvents(from: start, to: end)
        }
    }

    private func navigateYear(by value: Int) {
        let cal = Calendar.current
        if let newDate = cal.date(byAdding: .year, value: value, to: vm.displayedMonth) {
            vm.displayedMonth = newDate
            Task {
                let year = cal.component(.year, from: newDate)
                let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? newDate
                let end   = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? newDate
                await vm.loadEvents(from: start, to: end)
            }
        }
    }
}

// MARK: - Mini Month View (used in Year view)

private struct MiniMonthView: View {
    let month: Date
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    private var days: [Date?] {
        let cal = Calendar.current
        guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay) - 1
        var result: [Date?] = Array(repeating: nil, count: weekday)
        let range = cal.range(of: .day, in: .month, for: month)!
        for day in 1...range.count {
            result.append(cal.date(from: DateComponents(year: cal.component(.year, from: month),
                                                        month: cal.component(.month, from: month),
                                                        day: day)))
        }
        // Pad to multiple of 7
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var monthName: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        return fmt.string(from: month)
    }

    private let weekLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year, .month, .day], from: Date())
        let isCurrentMonth: Bool = {
            let mc = cal.dateComponents([.year, .month], from: month)
            let dc = cal.dateComponents([.year, .month], from: vm.displayedMonth)
            return mc.year == dc.year && mc.month == dc.month
        }()

        VStack(spacing: 4) {
            Text(monthName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCurrentMonth ? theme.brandPrimary : theme.textPrimary)

            // Weekday labels
            HStack(spacing: 0) {
                ForEach(weekLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid
            let rows = days.chunked(into: 7)
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { colIdx in
                        let date = rows[rowIdx][colIdx]
                        Group {
                            if let date {
                                let dc = cal.dateComponents([.year, .month, .day], from: date)
                                let isToday = dc.year == todayComps.year && dc.month == todayComps.month && dc.day == todayComps.day
                                let hasEvent = vm.hasEvents(on: date)

                                ZStack {
                                    if isToday {
                                        Circle()
                                            .fill(theme.brandPrimary)
                                            .frame(width: 16, height: 16)
                                    }
                                    Text("\(dc.day ?? 0)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(isToday ? .white : theme.textPrimary)

                                    if hasEvent && !isToday {
                                        Circle()
                                            .fill(theme.brandPrimary)
                                            .frame(width: 3, height: 3)
                                            .offset(y: 6)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 16)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 16)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
        )
    }
}

// MARK: - Month View (with UICalendarView)

private struct MonthView: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NativeCalendarView(vm: vm)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .background(theme.divider)
                    .padding(.top, 4)

                dayEventSection

                calendarLegend
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var dayEventSection: some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"

        return VStack(spacing: 0) {
            HStack {
                Text(fmt.string(from: vm.selectedDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if !vm.eventsForSelectedDate.isEmpty {
                    Text("\(vm.eventsForSelectedDate.count) event\(vm.eventsForSelectedDate.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if vm.eventsForSelectedDate.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.title2)
                        .foregroundStyle(theme.textTertiary.opacity(0.5))
                    Text("No events")
                        .font(.subheadline)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(vm.eventsForSelectedDate, id: \.id) { event in
                        CalendarEventRow(event: event, vm: vm)
                            .onTapGesture { vm.selectedEvent = event }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private var calendarLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(vm.calendars) { calendar in
                    Button {
                        if vm.visibleCalendarIds.contains(calendar.id) {
                            vm.visibleCalendarIds.remove(calendar.id)
                        } else {
                            vm.visibleCalendarIds.insert(calendar.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(calendar.swiftUIColor)
                                .frame(width: 10, height: 10)
                                .opacity(vm.visibleCalendarIds.contains(calendar.id) ? 1 : 0.3)
                            Text(calendar.name)
                                .font(.caption)
                                .foregroundStyle(
                                    vm.visibleCalendarIds.contains(calendar.id)
                                        ? theme.textPrimary
                                        : theme.textTertiary
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Week View

private struct WeekView: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    private let hourHeight: CGFloat = 54
    private let timeColumnWidth: CGFloat = 44

    private var weekDays: [Date] { vm.currentWeekDays }

    var body: some View {
        VStack(spacing: 0) {
            // Week navigation header (prev/next + day columns)
            weekNavigationHeader

            Divider().background(theme.divider)

            // All-day events bar
            if !allDayEvents.isEmpty {
                allDayBar
                Divider().background(theme.divider)
            }

            // Timed grid
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Single GeometryReader wraps the whole grid so events can
                    // compute their positions without expanding the ZStack.
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            // Hour lines + labels
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    HStack(alignment: .top, spacing: 0) {
                                        Text(hourLabel(hour))
                                            .font(.system(size: 10))
                                            .foregroundStyle(theme.textTertiary)
                                            .frame(width: timeColumnWidth, alignment: .trailing)
                                            .padding(.trailing, 4)
                                            .offset(y: -6)

                                        Rectangle()
                                            .fill(theme.divider.opacity(0.4))
                                            .frame(height: 0.5)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .frame(height: hourHeight)
                                    .id(hour)
                                }
                            }

                            // All events for the week, laid out inside a single geo context
                            let totalWidth = geo.size.width
                            let colWidth = (totalWidth - timeColumnWidth) / CGFloat(weekDays.count)

                            ForEach(weekDays.indices, id: \.self) { idx in
                                let day = weekDays[idx]
                                let dayEvents = vm.events(on: day).filter { !$0.allDay }
                                ForEach(dayEvents, id: \.id) { event in
                                    let startMins = minutesFromMidnight(event.startAt)
                                    let endMins = event.endAt.map { minutesFromMidnight($0) } ?? (startMins + 60)
                                    let yOffset = CGFloat(startMins) / 60.0 * hourHeight
                                    let blockHeight = max(CGFloat(endMins - startMins) / 60.0 * hourHeight, 22)
                                    let xOffset = timeColumnWidth + CGFloat(idx) * colWidth

                                    Button { vm.selectedEvent = event } label: {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill((event.swiftUIColor ?? vm.color(for: event.calendarId)).opacity(0.85))
                                            .overlay(alignment: .topLeading) {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(event.title)
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                        .lineLimit(1)
                                                    if blockHeight > 32, let end = event.endAt {
                                                        Text(shortTime(event.startAt) + " – " + shortTime(end))
                                                            .font(.system(size: 9))
                                                            .foregroundStyle(.white.opacity(0.85))
                                                    }
                                                }
                                                .padding(.horizontal, 3)
                                                .padding(.vertical, 2)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: colWidth - 3, height: blockHeight)
                                    .offset(x: xOffset + 1, y: yOffset)
                                }
                            }

                            // Current time indicator
                            let now = Date()
                            let cal = Calendar.current
                            let mins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
                            let nowY = CGFloat(mins) / 60.0 * hourHeight

                            ZStack(alignment: .leading) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: timeColumnWidth - 4, y: nowY - 3.5)
                                Rectangle()
                                    .fill(Color.red.opacity(0.75))
                                    .frame(height: 1.5)
                                    .padding(.leading, timeColumnWidth)
                                    .offset(y: nowY)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: geo.size.width, height: CGFloat(24) * hourHeight)
                    }
                    // Give the GeometryReader a concrete height so it doesn't collapse
                    .frame(height: CGFloat(24) * hourHeight)
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    let cal = Calendar.current
                    let hour = cal.component(.hour, from: Date())
                    proxy.scrollTo(max(0, hour - 1), anchor: .top)
                }
            }
        }
        .task { await loadWeekEvents() }
    }

    // MARK: Week Navigation Header

    private var weekNavigationHeader: some View {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year, .month, .day], from: Date())
        return HStack(spacing: 0) {
            // Spacer matching the time column width
            Color.clear.frame(width: timeColumnWidth)

            // Day columns
            ForEach(weekDays, id: \.self) { day in
                let dc = cal.dateComponents([.year, .month, .day], from: day)
                let isToday = dc.year == todayComps.year && dc.month == todayComps.month && dc.day == todayComps.day
                let isSelected = cal.isDate(day, inSameDayAs: vm.selectedDate)
                Button {
                    vm.selectedDate = day
                } label: {
                    VStack(spacing: 2) {
                        Text(weekdayAbbrev(day))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isToday ? theme.brandPrimary : theme.textTertiary)

                        ZStack {
                            if isToday {
                                Circle().fill(theme.brandPrimary).frame(width: 28, height: 28)
                            } else if isSelected {
                                Circle().fill(theme.brandPrimary.opacity(0.18)).frame(width: 28, height: 28)
                            }
                            Text("\(dc.day ?? 0)")
                                .font(.system(size: 15, weight: isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? .white : (isSelected ? theme.brandPrimary : theme.textPrimary))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.background)
        // Swipe left = next week, swipe right = previous week
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { val in
                    guard abs(val.translation.width) > abs(val.translation.height) else { return }
                    if val.translation.width < -30 {
                        navigateWeek(by: 1)
                    } else if val.translation.width > 30 {
                        navigateWeek(by: -1)
                    }
                }
        )
    }

    // MARK: All-day bar

    private var allDayEvents: [CalendarEvent] {
        let cal = Calendar.current
        return vm.events
            .filter { vm.visibleCalendarIds.contains($0.calendarId) }
            .filter { $0.allDay }
            .filter { event in weekDays.contains { cal.isDate(event.startAt, inSameDayAs: $0) } }
    }

    private var allDayBar: some View {
        HStack(spacing: 4) {
            Text("All-day")
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(allDayEvents, id: \.id) { event in
                        Button { vm.selectedEvent = event } label: {
                            Text(event.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (event.swiftUIColor ?? vm.color(for: event.calendarId)).opacity(0.85),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 4)
        .background(theme.surfaceContainer.opacity(0.4))
    }

    // MARK: Navigation helpers

    private func navigateWeek(by weeks: Int) {
        let cal = Calendar.current
        if let newDate = cal.date(byAdding: .weekOfYear, value: weeks, to: vm.selectedDate) {
            vm.selectedDate = newDate
            Task { await loadWeekEvents() }
        }
    }

    private func loadWeekEvents() async {
        let cal = Calendar.current
        guard let first = weekDays.first, let last = weekDays.last else { return }
        let start = cal.startOfDay(for: first)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last
        await vm.loadEvents(from: start, to: end)
    }

    // MARK: Helpers

    private func weekdayAbbrev(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func minutesFromMidnight(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "h:mm"
        return fmt.string(from: date)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }
}

// MARK: - Day View

private struct DayView: View {
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    private let hourHeight: CGFloat = 60
    private let timeColumnWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            // Day navigation strip
            dayStrip

            Divider().background(theme.divider)

            // All-day events
            if !allDayEvents.isEmpty {
                allDayBar
            }

            // Timed events timeline
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        // Hour lines
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(hourLabel(hour))
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: timeColumnWidth, alignment: .trailing)
                                        .padding(.trailing, 6)
                                        .offset(y: -6)

                                    Rectangle()
                                        .fill(theme.divider.opacity(0.5))
                                        .frame(height: 0.5)
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(height: hourHeight)
                                .id(hour)
                            }
                        }

                        // Events
                        GeometryReader { geo in
                            ForEach(timedEvents, id: \.id) { event in
                                dayEventBlock(event: event, geo: geo)
                            }

                            // Current time line
                            currentTimeLine(geo: geo)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(24) * hourHeight)
                    }
                    .padding(.top, 4)
                }
                .onAppear {
                    let cal = Calendar.current
                    let hour = cal.component(.hour, from: Date())
                    proxy.scrollTo(max(0, hour - 1), anchor: .top)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 40, coordinateSpace: .local)
                    .onEnded { val in
                        if val.translation.width < -60 {
                            navigateDay(by: 1)
                        } else if val.translation.width > 60 {
                            navigateDay(by: -1)
                        }
                    }
            )
        }
        .task { await loadDayEvents() }
    }

    private func navigateDay(by days: Int) {
        let cal = Calendar.current
        if let newDate = cal.date(byAdding: .day, value: days, to: vm.selectedDate) {
            vm.selectedDate = newDate
            Task { await loadDayEvents() }
        }
    }

    private func loadDayEvents() async {
        let cal = Calendar.current
        let start = cal.startOfDay(for: vm.selectedDate)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        await vm.loadEvents(from: start, to: end)
    }

    private var timedEvents: [CalendarEvent] {
        vm.events(on: vm.selectedDate).filter { !$0.allDay }
    }

    private var allDayEvents: [CalendarEvent] {
        vm.events(on: vm.selectedDate).filter { $0.allDay }
    }

    // MARK: Day strip (date picker row)

    private var dayStrip: some View {
        let cal = Calendar.current
        // Show a 7-day strip centred on today
        let today = vm.selectedDate
        let offsets = (-3)...3
        let days = offsets.compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let todayComps = cal.dateComponents([.year, .month, .day], from: Date())

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Previous week arrow
                Button { navigateDay(by: -7) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 32, height: 50)
                }
                .buttonStyle(.plain)

                ForEach(days, id: \.self) { day in
                    let dc = cal.dateComponents([.year, .month, .day], from: day)
                    let isToday = dc.year == todayComps.year && dc.month == todayComps.month && dc.day == todayComps.day
                    let isSelected = cal.isDate(day, inSameDayAs: vm.selectedDate)
                    let wdFmt: DateFormatter = {
                        let f = DateFormatter(); f.dateFormat = "EEE"; return f
                    }()
                    Button {
                        vm.selectedDate = day
                        Task { await loadDayEvents() }
                    } label: {
                        VStack(spacing: 3) {
                            Text(wdFmt.string(from: day).uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isToday ? theme.brandPrimary : theme.textTertiary)
                            ZStack {
                                if isSelected {
                                    Circle().fill(theme.brandPrimary).frame(width: 30, height: 30)
                                } else if isToday {
                                    Circle().fill(theme.brandPrimary.opacity(0.2)).frame(width: 30, height: 30)
                                }
                                Text("\(dc.day ?? 0)")
                                    .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                                    .foregroundStyle(isSelected ? .white : (isToday ? theme.brandPrimary : theme.textPrimary))
                            }
                            // Dot if has events
                            Circle()
                                .fill(vm.hasEvents(on: day) ? theme.brandPrimary : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(width: 40)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }

                // Next week arrow
                Button { navigateDay(by: 7) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 32, height: 50)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .background(theme.background)
    }

    // MARK: All-day bar

    private var allDayBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allDayEvents, id: \.id) { event in
                    Button {
                        vm.selectedEvent = event
                    } label: {
                        Text(event.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background((event.swiftUIColor ?? vm.color(for: event.calendarId)).opacity(0.85),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(theme.surfaceContainer.opacity(0.4))
    }

    // MARK: Event block

    @ViewBuilder
    private func dayEventBlock(event: CalendarEvent, geo: GeometryProxy) -> some View {
        let startMins = minutesFromMidnight(event.startAt)
        let endMins = event.endAt.map { minutesFromMidnight($0) } ?? (startMins + 60)
        let yOffset = CGFloat(startMins) / 60.0 * hourHeight
        let height = max(CGFloat(endMins - startMins) / 60.0 * hourHeight, 24)
        let xOffset = timeColumnWidth + 2
        let width = geo.size.width - timeColumnWidth - 8

        Button {
            vm.selectedEvent = event
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(event.swiftUIColor ?? vm.color(for: event.calendarId))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    if let end = event.endAt, height > 36 {
                        Text(shortTime(event.startAt) + " – " + shortTime(end))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if let loc = event.location, !loc.isEmpty, height > 54 {
                        Text(loc)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Spacer(minLength: 0)
            }
            .frame(width: width, height: height)
            .background((event.swiftUIColor ?? vm.color(for: event.calendarId)).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder((event.swiftUIColor ?? vm.color(for: event.calendarId)).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .position(x: xOffset + width / 2, y: yOffset + height / 2)
    }

    // MARK: Current time line

    @ViewBuilder
    private func currentTimeLine(geo: GeometryProxy) -> some View {
        let cal = Calendar.current
        let now = Date()
        // Only show on today
        if cal.isDateInToday(vm.selectedDate) {
            let mins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            let y = CGFloat(mins) / 60.0 * hourHeight

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.red.opacity(0.75))
                    .frame(height: 1.5)
                    .frame(width: geo.size.width - timeColumnWidth)
                    .offset(x: timeColumnWidth, y: y)
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: timeColumnWidth - 4, y: y - 3)
            }
            .frame(width: geo.size.width, height: CGFloat(24) * hourHeight)
            .allowsHitTesting(false)
        }
    }

    // MARK: Helpers

    private func minutesFromMidnight(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }
}

// MARK: - Native UICalendarView Wrapper (Month view)

private struct NativeCalendarView: UIViewRepresentable {
    @Bindable var vm: CalendarViewModel
    @Environment(\.theme) private var theme

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.calendar = Calendar.current
        calendarView.locale = Locale.current
        calendarView.fontDesign = .rounded
        calendarView.tintColor = UIColor(theme.brandPrimary)

        calendarView.availableDateRange = DateInterval(
            start: Calendar.current.date(byAdding: .year, value: -10, to: Date()) ?? Date(),
            end: Calendar.current.date(byAdding: .year, value: 10, to: Date()) ?? Date()
        )

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        calendarView.selectionBehavior = selection
        context.coordinator.selection = selection
        calendarView.delegate = context.coordinator
        context.coordinator.calendarView = calendarView

        let today = Calendar.current.dateComponents([.calendar, .year, .month, .day], from: vm.selectedDate)
        selection.setSelected(today, animated: false)

        calendarView.setContentHuggingPriority(.required, for: .vertical)

        return calendarView
    }

    func updateUIView(_ calendarView: UICalendarView, context: Context) {
        calendarView.tintColor = UIColor(theme.brandPrimary)
        context.coordinator.vm = vm

        // BOUNCE-FIX: Only programmatically navigate when explicitly requested
        // (e.g. "Today" button sets needsNavigateToSelected = true).
        // Never fight UICalendarView's own month navigation.
        if vm.needsNavigateToSelected {
            let targetComponents = Calendar.current.dateComponents([.calendar, .year, .month, .day], from: vm.selectedDate)
            context.coordinator.selection?.setSelected(targetComponents, animated: true)

            if let targetDate = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: vm.selectedDate)) {
                calendarView.setVisibleDateComponents(
                    Calendar.current.dateComponents([.calendar, .year, .month], from: targetDate),
                    animated: true
                )
            }
            // Clear the flag so we don't navigate again on the next updateUIView
            DispatchQueue.main.async {
                vm.needsNavigateToSelected = false
            }
        }

        // Reload decorations when events change
        let allDates = vm.events.compactMap { event -> DateComponents? in
            Calendar.current.dateComponents([.calendar, .year, .month, .day], from: event.startAt)
        }
        if !allDates.isEmpty {
            calendarView.reloadDecorations(forDateComponents: allDates, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var vm: CalendarViewModel
        weak var calendarView: UICalendarView?
        var selection: UICalendarSelectionSingleDate?

        private var lastFetchedMonth: DateComponents?

        init(vm: CalendarViewModel) {
            self.vm = vm
        }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            let cal = Calendar.current
            guard let date = cal.date(from: dateComponents) else { return nil }

            let dayEvents = vm.events
                .filter { vm.visibleCalendarIds.contains($0.calendarId) }
                .filter { cal.isDate($0.startAt, inSameDayAs: date) }

            guard !dayEvents.isEmpty else { return nil }

            var seen = Set<String>()
            var colors: [UIColor] = []
            for event in dayEvents {
                if seen.insert(event.calendarId).inserted {
                    let swiftColor = event.swiftUIColor ?? vm.color(for: event.calendarId)
                    colors.append(UIColor(swiftColor))
                    if colors.count >= 3 { break }
                }
            }

            guard !colors.isEmpty else { return nil }

            let dotImage = createDotImage(colors: colors)
            return .image(dotImage, color: nil, size: .medium)
        }

        func calendarView(
            _ calendarView: UICalendarView,
            didChangeVisibleDateComponentsFrom previousDateComponents: DateComponents
        ) {
            let visible = calendarView.visibleDateComponents
            guard let year = visible.year, let month = visible.month else { return }
            let newMonth = DateComponents(year: year, month: month)

            if let last = lastFetchedMonth, last.year == newMonth.year, last.month == newMonth.month {
                return
            }
            lastFetchedMonth = newMonth

            if let date = Calendar.current.date(from: newMonth) {
                Task { @MainActor in
                    vm.displayedMonth = date
                    await vm.loadEventsForDisplayedMonth()
                }
            }
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            return dateComponents != nil
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents,
                  let date = Calendar.current.date(from: dateComponents) else { return }
            Task { @MainActor in
                vm.selectedDate = date
            }
        }

        private func createDotImage(colors: [UIColor]) -> UIImage {
            let dotDiameter: CGFloat = 5
            let spacing: CGFloat = 3
            let totalWidth = CGFloat(colors.count) * dotDiameter + CGFloat(colors.count - 1) * spacing
            let size = CGSize(width: max(totalWidth, 1), height: dotDiameter)

            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                for (i, color) in colors.enumerated() {
                    let x = CGFloat(i) * (dotDiameter + spacing)
                    let rect = CGRect(x: x, y: 0, width: dotDiameter, height: dotDiameter)
                    color.setFill()
                    UIBezierPath(ovalIn: rect).fill()
                }
            }
        }
    }
}

// MARK: - Event Row (shared)

struct CalendarEventRow: View {
    let event: CalendarEvent
    let vm: CalendarViewModel
    @Environment(\.theme) private var theme

    private var timeString: String {
        if event.allDay { return "All day" }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        if let end = event.endAt {
            return "\(fmt.string(from: event.startAt)) – \(fmt.string(from: end))"
        }
        return fmt.string(from: event.startAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.swiftUIColor ?? vm.color(for: event.calendarId))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)

                    if let loc = event.location, !loc.isEmpty {
                        Text("·")
                            .foregroundStyle(theme.textTertiary)
                        Text(loc)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }

                    if event.isRunEvent, let status = event.meta?.status {
                        Text("·")
                            .foregroundStyle(theme.textTertiary)
                        Label(
                            status == "success" ? "Success" : "Failed",
                            systemImage: status == "success" ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(status == "success" ? .green : .red)
                    }
                }
            }

            Spacer()

            if event.rrule != nil {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Array chunked helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
