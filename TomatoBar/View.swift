import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
}

private let settingsRowSpacing: CGFloat = 6
private let popoverContentWidth: CGFloat = 300
private let childPanelChromeHeight: CGFloat = 0
private let popoverPadding: CGFloat = 12
private let footerSpacing: CGFloat = 8
private let intervalNumberFieldWidth: CGFloat = 44
private let intervalUnitColumnPadding: CGFloat = 6
private let defaultHistoryChildPanelHeight: CGFloat = 264
private let defaultCompactChildPanelHeight: CGFloat = 190

private func withDisabledAnimation(_ updates: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        updates()
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ViewWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func onMeasuredHeightChange(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: onChange)
    }

    func onMeasuredWidthChange(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ViewWidthPreferenceKey.self, perform: onChange)
    }
}

private struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    @State private var unitColumnWidth: CGFloat = 0
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: settingsRowSpacing) {
            IntervalNumberRow(
                label: NSLocalizedString("IntervalsView.workIntervalLength.label",
                                         comment: "Work interval label"),
                value: $timer.workIntervalLength,
                range: 1 ... 60,
                unitLabel: NSLocalizedString("IntervalsView.minutesUnit",
                                             comment: "Minutes unit"),
                unitColumnWidth: unitColumnWidth,
                onUnitWidthChange: setUnitColumnWidth
            )
            IntervalNumberRow(
                label: NSLocalizedString("IntervalsView.shortRestIntervalLength.label",
                                         comment: "Short rest interval label"),
                value: $timer.shortRestIntervalLength,
                range: 1 ... 60,
                unitLabel: NSLocalizedString("IntervalsView.minutesUnit",
                                             comment: "Minutes unit"),
                unitColumnWidth: unitColumnWidth,
                onUnitWidthChange: setUnitColumnWidth
            )
            IntervalNumberRow(
                label: NSLocalizedString("IntervalsView.workIntervalsInSet.label",
                                         comment: "Work intervals in a set label"),
                value: $timer.workIntervalsInSet,
                range: 1 ... 10,
                unitLabel: NSLocalizedString("IntervalsView.intervalsUnit",
                                             comment: "Intervals unit"),
                unitColumnWidth: unitColumnWidth,
                onUnitWidthChange: setUnitColumnWidth
            )
            .help(NSLocalizedString("IntervalsView.workIntervalsInSet.help",
                                    comment: "Work intervals in set hint"))
            IntervalNumberRow(
                label: NSLocalizedString("IntervalsView.longRestIntervalLength.label",
                                         comment: "Long rest interval label"),
                value: $timer.longRestIntervalLength,
                range: 1 ... 60,
                unitLabel: NSLocalizedString("IntervalsView.minutesUnit",
                                             comment: "Minutes unit"),
                unitColumnWidth: unitColumnWidth,
                onUnitWidthChange: setUnitColumnWidth
            )
            .help(NSLocalizedString("IntervalsView.longRestIntervalLength.help",
                                    comment: "Long rest interval hint"))
            IntervalNumberRow(
                label: NSLocalizedString("IntervalsView.workSetsToRepeat.label",
                                         comment: "Work sets to repeat label"),
                value: $timer.workSetsToRepeat,
                range: 0 ... 24,
                unitLabel: NSLocalizedString("IntervalsView.setsUnit",
                                             comment: "Sets unit"),
                unitColumnWidth: unitColumnWidth,
                onUnitWidthChange: setUnitColumnWidth
            )
            .help(NSLocalizedString("IntervalsView.workSetsToRepeat.help",
                                    comment: "Work sets to repeat hint"))
        }
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
        .onMeasuredHeightChange(onContentHeightChange)
    }

    private func setUnitColumnWidth(_ width: CGFloat) {
        let roundedWidth = ceil(width + intervalUnitColumnPadding)
        guard roundedWidth > unitColumnWidth + 0.5 else {
            return
        }

        DispatchQueue.main.async {
            withDisabledAnimation {
                unitColumnWidth = roundedWidth
            }
        }
    }
}

private struct IntervalNumberRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unitLabel: String
    let unitColumnWidth: CGFloat
    let onUnitWidthChange: (CGFloat) -> Void

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 999
        formatter.numberStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                TextField("", value: clampedValue, formatter: Self.numberFormatter)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body).monospacedDigit())
                    .frame(width: intervalNumberFieldWidth)
                Text(unitLabel)
                    .foregroundColor(.secondary)
                    .fixedSize()
                    .onMeasuredWidthChange(onUnitWidthChange)
                    .frame(width: unitColumnWidth, alignment: .center)
            }
            .frame(width: intervalNumberFieldWidth + 8 + unitColumnWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct SettingsView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable
    @AppStorage("dailyFocusGoalMinutes") private var dailyFocusGoalMinutes = 120
    let contentHeight: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: settingsRowSpacing) {
                SettingsSection(title: NSLocalizedString("SettingsView.section.focus",
                                                         comment: "Focus settings section")) {
                    HStack(spacing: 8) {
                        Text(NSLocalizedString("SettingsView.dailyFocusGoal.label",
                                               comment: "Daily focus goal label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GoalDurationEditor(totalMinutes: $dailyFocusGoalMinutes)
                            .onChange(of: dailyFocusGoalMinutes) { _ in
                                timer.refreshWidgetSnapshot()
                            }
                    }
                }

                SettingsSection(title: NSLocalizedString("SettingsView.section.timer",
                                                         comment: "Timer settings section")) {
                    KeyboardShortcuts.Recorder(for: .startStopTimer) {
                        Text(NSLocalizedString("SettingsView.shortcut.label",
                                               comment: "Shortcut label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle(isOn: $timer.stopAfterBreak) {
                        Text(NSLocalizedString("SettingsView.stopAfterBreak.label",
                                               comment: "Stop after break label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Toggle(isOn: $timer.showTimerInMenuBar) {
                        Text(NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                               comment: "Show timer in menu bar label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: timer.showTimerInMenuBar) { _ in
                        timer.updateTimeLeft()
                    }
                }

                SettingsSection(title: NSLocalizedString("SettingsView.section.app",
                                                         comment: "App settings section")) {
                    Toggle(isOn: $launchAtLogin.isEnabled) {
                        Text(NSLocalizedString("SettingsView.launchAtLogin.label",
                                               comment: "Launch at login label"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsSection(title: NSLocalizedString("SettingsView.section.sound",
                                                         comment: "Sound settings section")) {
                    SoundsView().environmentObject(timer.player)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: contentHeight)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: settingsRowSpacing) {
            HStack(spacing: settingsRowSpacing) {
                sectionLine
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                sectionLine
            }
            VStack(alignment: .leading, spacing: settingsRowSpacing) {
                content
            }
        }
    }

    private var sectionLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
    }
}

private struct GoalDurationEditor: View {
    @Binding var totalMinutes: Int
    private let allowedTotalMinutes = 15 ... 720
    private let allowedHours = 0 ... 12
    private let allowedMinutes = 0 ... 59

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 999
        formatter.numberStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: hours, formatter: Self.numberFormatter)
                .multilineTextAlignment(.trailing)
                .font(.system(.body).monospacedDigit())
                .frame(width: 34)
            Text(NSLocalizedString("SettingsView.dailyFocusGoal.hours",
                                   comment: "Daily focus goal hours unit"))
                .foregroundColor(.secondary)
            TextField("", value: minutes, formatter: Self.numberFormatter)
                .multilineTextAlignment(.trailing)
                .font(.system(.body).monospacedDigit())
                .frame(width: 34)
            Text(NSLocalizedString("SettingsView.dailyFocusGoal.minutes",
                                   comment: "Daily focus goal minutes unit"))
                .foregroundColor(.secondary)
        }
    }

    private var hours: Binding<Int> {
        Binding(
            get: { totalMinutes / 60 },
            set: { newHours in
                let clampedHours = min(max(newHours, allowedHours.lowerBound), allowedHours.upperBound)
                totalMinutes = clampedTotalMinutes(hours: clampedHours,
                                                   minutes: totalMinutes % 60)
            }
        )
    }

    private var minutes: Binding<Int> {
        Binding(
            get: { totalMinutes % 60 },
            set: { newMinutes in
                let clampedMinutes = min(max(newMinutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
                totalMinutes = clampedTotalMinutes(hours: totalMinutes / 60,
                                                   minutes: clampedMinutes)
            }
        )
    }

    private func clampedTotalMinutes(hours: Int, minutes: Int) -> Int {
        min(max(hours * 60 + minutes, allowedTotalMinutes.lowerBound), allowedTotalMinutes.upperBound)
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 6) {
            TickedVolumeSlider(volume: $volume)
            Text("\(displayValue)")
                .font(.system(.caption).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .trailing)
        }
        .gesture(TapGesture(count: 2).onEnded({
            volume = 1.0
        }))
    }

    private var displayValue: Int {
        min(max(Int((volume * 10).rounded()), 0), 10)
    }
}

private struct TickedVolumeSlider: NSViewRepresentable {
    @Binding var volume: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: displayValue(from: volume),
                              minValue: 0,
                              maxValue: 10,
                              target: context.coordinator,
                              action: #selector(Coordinator.valueChanged(_:)))
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.controlSize = .small
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context _: Context) {
        let value = displayValue(from: volume)
        guard abs(slider.doubleValue - value) > 0.01 else {
            return
        }
        slider.doubleValue = value
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(volume: $volume)
    }

    private func displayValue(from volume: Double) -> Double {
        Double(min(max(Int((volume * 10).rounded()), 0), 10))
    }

    final class Coordinator: NSObject {
        private var volume: Binding<Double>

        init(volume: Binding<Double>) {
            self.volume = volume
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let steppedValue = min(max(Int(sender.doubleValue.rounded()), 0), 10)
            sender.doubleValue = Double(steppedValue)
            volume.wrappedValue = Double(steppedValue) / 10
        }
    }
}

private struct SoundsView: View {
    @EnvironmentObject var player: TBPlayer

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(132))
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: settingsRowSpacing) {
            Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                   comment: "Windup label"))
            VolumeSlider(volume: $player.windupVolume)
            Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                   comment: "Ding label"))
            VolumeSlider(volume: $player.dingVolume)
            Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                   comment: "Ticking label"))
            VolumeSlider(volume: $player.tickingVolume)
        }
    }
}

private struct CycleDotsView: View {
    @EnvironmentObject var timer: TBTimer

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1 ... timer.cycleTotal, id: \.self) { index in
                Circle()
                    .fill(fillColor(for: index))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(index == timer.cycleActiveIndex ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
            }
        }
    }

    private func fillColor(for index: Int) -> Color {
        if index <= timer.cycleCompletedCount {
            return Color.accentColor
        }
        return Color.secondary.opacity(0.25)
    }
}

private struct TimerStatusView: View {
    @EnvironmentObject var timer: TBTimer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timer.statusTitle)
                    .font(.headline)
                Spacer()
                Text(timer.timeLeftString)
                    .font(.system(.title3).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text(timer.nextStepDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CycleDotsView().environmentObject(timer)
            }
        }
    }
}

private struct StopwatchStatusView: View {
    @EnvironmentObject var timer: TBTimer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timer.statusTitle)
                    .font(.headline)
                Spacer()
                Text(timer.timeLeftString)
                    .font(.system(.title3).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text(timer.nextStepDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct TimerModePicker: View {
    @EnvironmentObject var timer: TBTimer

    var body: some View {
        Picker("", selection: modeBinding) {
            Text(NSLocalizedString("TBTimerMode.pomodoro.label", comment: "Pomodoro mode label"))
                .tag(TBTimerMode.pomodoro)
            Text(NSLocalizedString("TBTimerMode.stopwatch.label", comment: "Stopwatch mode label"))
                .tag(TBTimerMode.stopwatch)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .disabled(!timer.canChangeTimerMode)
    }

    private var modeBinding: Binding<TBTimerMode> {
        Binding(
            get: { timer.timerMode },
            set: { mode in
                guard mode != timer.timerMode else {
                    return
                }
                DispatchQueue.main.async {
                    timer.setTimerMode(mode)
                }
            }
        )
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case week, month

    var id: String { rawValue }

    var calendarComponent: Calendar.Component {
        switch self {
        case .week:
            return .weekOfYear
        case .month:
            return .month
        }
    }

    var localizedLabel: String {
        switch self {
        case .week:
            return NSLocalizedString("HistoryRange.week.label", comment: "Week history range label")
        case .month:
            return NSLocalizedString("HistoryRange.month.label", comment: "Month history range label")
        }
    }
}

private struct HistoryRangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HistoryRange.allCases) { range in
                Button {
                    withDisabledAnimation {
                        selection = range
                    }
                } label: {
                    Text(range.localizedLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selection == range ? Color.accentColor : Color.clear)
                        )
                        .foregroundColor(selection == range ? .white : .primary)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
        .frame(width: 132)
    }
}

private struct HistoryPeriodOverviewView: View {
    let range: HistoryRange
    let totals: [TBDailyFocusTotal]
    let selectedDate: Date
    let goalDurationSeconds: Int
    let onSelectDate: (Date) -> Void

    @ViewBuilder
    var body: some View {
        switch range {
        case .week:
            HistoryWeekBarsView(
                totals: totals,
                selectedDate: selectedDate,
                goalDurationSeconds: goalDurationSeconds,
                onSelectDate: onSelectDate
            )
        case .month:
            HistoryMonthGridView(
                totals: totals,
                selectedDate: selectedDate,
                goalDurationSeconds: goalDurationSeconds,
                onSelectDate: onSelectDate
            )
        }
    }
}

private struct HistoryWeekBarsView: View {
    let totals: [TBDailyFocusTotal]
    let selectedDate: Date
    let goalDurationSeconds: Int
    let onSelectDate: (Date) -> Void
    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(totals) { total in
                Button {
                    onSelectDate(total.date)
                } label: {
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(fillColor(for: total.durationSeconds))
                            .frame(height: barHeight(for: total.durationSeconds))
                        Text(dayLabel(for: total.date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(dayNumber(for: total.date))
                            .font(.caption2)
                            .foregroundColor(isSelected(total.date) ? .primary : .secondary)
                            .frame(minWidth: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected(total.date) ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help(goalProgressSummary(durationSeconds: total.durationSeconds,
                                          goalDurationSeconds: goalDurationSeconds))
            }
        }
        .frame(height: 68)
    }

    private func barHeight(for durationSeconds: Int) -> CGFloat {
        guard durationSeconds > 0 else {
            return 3
        }

        return max(progressRatio(for: durationSeconds) * 34, 6)
    }

    private func fillColor(for durationSeconds: Int) -> Color {
        guard durationSeconds > 0 else {
            return Color.secondary.opacity(0.2)
        }

        let ratio = progressRatio(for: durationSeconds)
        return Color.accentColor.opacity(0.25 + 0.65 * ratio)
    }

    private func progressRatio(for durationSeconds: Int) -> CGFloat {
        min(CGFloat(durationSeconds) / CGFloat(max(goalDurationSeconds, 1)), 1)
    }

    private func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return String(formatter.string(from: date).prefix(1))
    }

    private func dayNumber(for date: Date) -> String {
        let component = calendar.component(.day, from: date)
        return "\(component)"
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }
}

private struct HistoryMonthGridView: View {
    let totals: [TBDailyFocusTotal]
    let selectedDate: Date
    let goalDurationSeconds: Int
    let onSelectDate: (Date) -> Void
    private let cellHeight: CGFloat = 20
    private let columnCount = 7
    private let spacing: CGFloat = 3
    private let calendar = Calendar.current

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, total in
                if let total {
                    HistoryMonthDayCell(
                        date: total.date,
                        durationSeconds: total.durationSeconds,
                        goalDurationSeconds: goalDurationSeconds,
                        cellHeight: cellHeight,
                        isSelected: calendar.isDate(total.date, inSameDayAs: selectedDate),
                        onSelectDate: onSelectDate
                    )
                } else {
                    Color.clear
                        .frame(height: cellHeight)
                }
            }
        }
        .frame(height: gridHeight, alignment: .top)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var monthCells: [TBDailyFocusTotal?] {
        guard let firstDate = totals.first?.date else {
            return []
        }

        let leadingEmptyCells = leadingEmptyCellCount(for: firstDate)
        return Array(repeating: nil, count: leadingEmptyCells) + totals.map(Optional.some)
    }

    private var gridHeight: CGFloat {
        let rowCount = max((monthCells.count + columnCount - 1) / columnCount, 1)
        return CGFloat(rowCount) * cellHeight + CGFloat(rowCount - 1) * spacing
    }

    private func leadingEmptyCellCount(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

private struct HistoryMonthDayCell: View {
    let date: Date
    let durationSeconds: Int
    let goalDurationSeconds: Int
    let cellHeight: CGFloat
    let isSelected: Bool
    let onSelectDate: (Date) -> Void
    private let calendar = Calendar.current

    var body: some View {
        Button {
            onSelectDate(date)
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.caption2)
                .foregroundColor(durationSeconds > 0 ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(goalProgressSummary(durationSeconds: durationSeconds,
                                  goalDurationSeconds: goalDurationSeconds))
    }

    private var fillColor: Color {
        guard durationSeconds > 0 else {
            return Color.secondary.opacity(0.08)
        }

        let ratio = min(CGFloat(durationSeconds) / CGFloat(max(goalDurationSeconds, 1)), 1)
        return Color.accentColor.opacity(0.22 + 0.55 * ratio)
    }
}

private struct HistoryView: View {
    @ObservedObject var timer: TBTimer
    @ObservedObject var history: TBFocusHistoryStore
    @Binding var range: HistoryRange
    let onContentHeightChange: (CGFloat) -> Void
    @AppStorage("dailyFocusGoalMinutes") private var dailyFocusGoalMinutes = 120
    @State private var selectedDate = Date()
    @State private var visibleDate = Date()
    private let sessionRowHeight: CGFloat = 32
    private let sessionRowSpacing: CGFloat = 4
    private let calendar = Calendar.current

    var body: some View {
        let selectedSessions = history.sessions(on: selectedDate)
        let selectedDuration = totalFocusTime(on: selectedDate)
        let periodStart = startOfPeriod(containing: visibleDate, range: range)
        let periodTotals = dailyTotals(from: periodStart, days: dayCount(inPeriodStarting: periodStart))
        let goalDurationSeconds = dailyFocusGoalMinutes * 60

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedDateTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(goalLabel(goalDurationSeconds: goalDurationSeconds))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(durationString(selectedDuration))
                        .font(.system(.headline).monospacedDigit())
                        .lineLimit(1)
                    Text(goalProgressText(durationSeconds: selectedDuration,
                                          goalDurationSeconds: goalDurationSeconds))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                HistoryRangePicker(selection: $range)
                    .onChange(of: range) { _ in
                        visibleDate = selectedDate
                    }
                Spacer()
                Button {
                    selectToday()
                } label: {
                    Text(NSLocalizedString("HistoryView.todayButton.label", comment: "Today button label"))
                        .lineLimit(1)
                        .frame(minWidth: 40)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(calendar.isDateInToday(selectedDate))
                historyActionsMenu
            }

            HStack(spacing: 8) {
                Button {
                    movePeriod(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text(periodTitle(startingAt: periodStart))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                Button {
                    movePeriod(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveForward)
            }

            HistoryPeriodOverviewView(
                range: range,
                totals: periodTotals,
                selectedDate: selectedDate,
                goalDurationSeconds: goalDurationSeconds,
                onSelectDate: selectDate
            )

            Divider()

            if selectedSessions.isEmpty {
                Text(NSLocalizedString("HistoryView.emptyForDate.label", comment: "No focus sessions for selected date label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: sessionRowSpacing) {
                        ForEach(selectedSessions) { session in
                            HistorySessionRow(session: session) {
                                history.deleteSession(id: session.id)
                            }
                            .frame(height: sessionRowHeight)
                        }
                    }
                }
                .frame(height: historyListHeight(for: selectedSessions.count))
            }
        }
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
        .onMeasuredHeightChange(onContentHeightChange)
    }

    private func historyListHeight(for sessionCount: Int) -> CGFloat {
        let visibleRows = min(sessionCount, 2)
        guard visibleRows > 0 else {
            return 0
        }
        let visibleSpacing = max(visibleRows - 1, 0)
        return CGFloat(visibleRows) * sessionRowHeight + CGFloat(visibleSpacing) * sessionRowSpacing
    }

    private func totalFocusTime(on date: Date) -> Int {
        history.totalFocusTime(on: date) + timer.liveFocusDuration(on: date, calendar: calendar)
    }

    private func dailyTotals(from startDate: Date, days: Int) -> [TBDailyFocusTotal] {
        history.dailyTotals(from: startDate, days: days).map { total in
            TBDailyFocusTotal(
                date: total.date,
                durationSeconds: total.durationSeconds + timer.liveFocusDuration(on: total.date, calendar: calendar)
            )
        }
    }

    private var historyActionsMenu: some View {
        Menu {
            Button {
                history.deleteSessions(on: selectedDate)
            } label: {
                Label(NSLocalizedString("HistoryView.deleteSelectedDate.label", comment: "Delete selected date history label"),
                      systemImage: "calendar.badge.minus")
            }
            .disabled(!history.hasSessions(on: selectedDate))

            Button {
                history.deleteAllSessions()
            } label: {
                Label(NSLocalizedString("HistoryView.deleteAll.label", comment: "Delete all history label"),
                      systemImage: "trash")
            }
            .disabled(history.sessions.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.medium)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("HistoryView.actions.help", comment: "History actions help"))
    }

    private var selectedDateTitle: String {
        if calendar.isDateInToday(selectedDate) {
            return NSLocalizedString("HistoryView.today.label", comment: "Today label")
        }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: selectedDate)
    }

    private var canMoveForward: Bool {
        let start = startOfPeriod(containing: visibleDate, range: range)
        guard let nextPeriod = calendar.date(byAdding: range.calendarComponent, value: 1, to: start) else {
            return false
        }
        return nextPeriod <= startOfPeriod(containing: Date(), range: range)
    }

    private func selectDate(_ date: Date) {
        selectedDate = date
        visibleDate = date
    }

    private func selectToday() {
        selectDate(Date())
    }

    private func movePeriod(by value: Int) {
        let currentStart = startOfPeriod(containing: visibleDate, range: range)
        let selectedOffset = calendar.dateComponents(
            [.day],
            from: currentStart,
            to: calendar.startOfDay(for: selectedDate)
        ).day ?? 0

        guard let nextVisibleDate = calendar.date(byAdding: range.calendarComponent, value: value, to: visibleDate) else {
            return
        }

        let nextStart = startOfPeriod(containing: nextVisibleDate, range: range)
        let nextDayCount = dayCount(inPeriodStarting: nextStart)
        let clampedOffset = min(max(selectedOffset, 0), max(nextDayCount - 1, 0))
        let nextSelectedDate = calendar.date(byAdding: .day, value: clampedOffset, to: nextStart) ?? nextStart
        selectDate(nextSelectedDate)
    }

    private func startOfPeriod(containing date: Date, range: HistoryRange) -> Date {
        calendar.dateInterval(of: range.calendarComponent, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private func dayCount(inPeriodStarting startDate: Date) -> Int {
        guard let endDate = calendar.date(byAdding: range.calendarComponent, value: 1, to: startDate) else {
            return range == .week ? 7 : 30
        }
        return max(calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0, 1)
    }

    private func periodTitle(startingAt startDate: Date) -> String {
        switch range {
        case .week:
            return weekTitle(startingAt: startDate)
        case .month:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
            return formatter.string(from: startDate)
        }
    }

    private func weekTitle(startingAt startDate: Date) -> String {
        let dayCount = dayCount(inPeriodStarting: startDate)
        let endDate = calendar.date(byAdding: .day, value: max(dayCount - 1, 0), to: startDate) ?? startDate
        let startFormatter = DateFormatter()
        let endFormatter = DateFormatter()
        let endTemplate = calendar.isDate(startDate, equalTo: endDate, toGranularity: .year)
            ? "MMM d"
            : "MMM d yyyy"
        startFormatter.setLocalizedDateFormatFromTemplate("MMM d")
        endFormatter.setLocalizedDateFormatFromTemplate(endTemplate)
        return "\(startFormatter.string(from: startDate)) - \(endFormatter.string(from: endDate))"
    }
}

private struct HistorySessionRow: View {
    let session: TBFocusSession
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRangeString(session))
                    .font(.caption)
                Text(sessionLabel(session))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(durationString(session.durationSeconds))
                .font(.system(.caption).monospacedDigit())
                .foregroundColor(session.completed ? .primary : .secondary)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help(NSLocalizedString("HistoryView.deleteSession.help", comment: "Delete session help"))
        }
    }
}

private enum ChildView: CaseIterable, Identifiable {
    case history, intervals, settings

    var id: Self { self }

    var localizedLabel: String {
        switch self {
        case .history:
            return NSLocalizedString("TBPopoverView.history.label", comment: "History label")
        case .intervals:
            return NSLocalizedString("TBPopoverView.intervals.label", comment: "Intervals label")
        case .settings:
            return NSLocalizedString("TBPopoverView.settings.label", comment: "Settings label")
        }
    }

    func childPanelHeight(historyHeight: CGFloat, compactHeight: CGFloat) -> CGFloat {
        switch self {
        case .history:
            return historyHeight
        case .intervals, .settings:
            return compactHeight
        }
    }

}

private struct ChildViewPicker: View {
    @Binding var selection: ChildView

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChildView.allCases) { childView in
                Button {
                    withDisabledAnimation {
                        selection = childView
                    }
                } label: {
                    Text(childView.localizedLabel)
                        .font(.body)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selection == childView ? Color.accentColor : Color.clear)
                        )
                        .foregroundColor(selection == childView ? .white : .primary)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
        .frame(maxWidth: .infinity)
    }
}

struct TBPopoverView: View {
    @StateObject private var timer = TBTimer()
    @State private var activeChildView = ChildView.history
    @State private var historyRange = HistoryRange.week
    @State private var historyChildPanelHeight = defaultHistoryChildPanelHeight
    @State private var compactChildPanelHeight = defaultCompactChildPanelHeight
    @State private var measuredPopoverContentHeight: CGFloat = 0

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")
    private var pauseLabel = NSLocalizedString("TBStopwatch.pause.label", comment: "Pause label")
    private var resumeLabel = NSLocalizedString("TBStopwatch.resume.label", comment: "Resume label")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimerModePicker().environmentObject(timer)

            if timer.timerMode == .stopwatch {
                StopwatchStatusView().environmentObject(timer)
            } else {
                TimerStatusView().environmentObject(timer)
            }

            if showsSplitTimerControls {
                HStack(spacing: 8) {
                    Button {
                        timer.startStop()
                    } label: {
                        primaryActionText(splitPrimaryButtonLabel)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.space, modifiers: [])
                    .frame(maxWidth: .infinity)

                    Button {
                        stopActiveTimer()
                    } label: {
                        Text(stopLabel)
                            .font(.system(.body).monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    timer.startStop()
                } label: {
                    primaryActionText(primaryButtonLabel)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.space, modifiers: [])
            }

            ChildViewPicker(selection: $activeChildView)

            VStack(alignment: .leading, spacing: footerSpacing) {
                childPanelView
                footerView
            }
        }
        .padding(.top, popoverPadding)
        .padding(.horizontal, popoverPadding)
        .padding(.bottom, footerSpacing)
        .frame(width: popoverContentWidth, alignment: .top)
        .onMeasuredHeightChange(setPopoverContentHeight)
        .onAppear(perform: updatePopoverContentSize)
    }

    private func updatePopoverContentSize() {
        guard measuredPopoverContentHeight > 0 else {
            return
        }

        TBStatusItem.shared.setPopoverContentSize(
            width: popoverContentWidth,
            height: measuredPopoverContentHeight
        )
    }

    private var footerView: some View {
        VStack(alignment: .leading, spacing: footerSpacing) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel()
            } label: {
                Text(NSLocalizedString("TBPopoverView.about.label",
                                       comment: "About label"))
                Spacer()
                Text("⌘ A").foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a")

            Button {
                NSApplication.shared.terminate(self)
            } label: {
                Text(NSLocalizedString("TBPopoverView.quit.label",
                                       comment: "Quit label"))
                Spacer()
                Text("⌘ Q").foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var childPanelView: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
            childPanelContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: activeChildView.childPanelHeight(historyHeight: historyChildPanelHeight,
                                                        compactHeight: compactChildPanelHeight),
               alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private var childPanelContent: some View {
        switch activeChildView {
        case .history:
            HistoryView(timer: timer,
                        history: timer.focusHistory,
                        range: $historyRange,
                        onContentHeightChange: setHistoryContentHeight)
        case .intervals:
            IntervalsView(onContentHeightChange: setCompactContentHeight)
                .environmentObject(timer)
        case .settings:
            SettingsView(contentHeight: compactChildContentHeight)
                .environmentObject(timer)
        }
    }

    private var compactChildContentHeight: CGFloat {
        max(compactChildPanelHeight - childPanelChromeHeight, 0)
    }

    private func setHistoryContentHeight(_ contentHeight: CGFloat) {
        setPanelHeight(contentHeight + childPanelChromeHeight, binding: $historyChildPanelHeight)
    }

    private func setCompactContentHeight(_ contentHeight: CGFloat) {
        setPanelHeight(contentHeight + childPanelChromeHeight, binding: $compactChildPanelHeight)
    }

    private func setPopoverContentHeight(_ contentHeight: CGFloat) {
        let roundedHeight = ceil(contentHeight)
        guard roundedHeight > 0, abs(measuredPopoverContentHeight - roundedHeight) > 0.5 else {
            return
        }

        DispatchQueue.main.async {
            withDisabledAnimation {
                measuredPopoverContentHeight = roundedHeight
            }
            TBStatusItem.shared.setPopoverContentSize(
                width: popoverContentWidth,
                height: roundedHeight
            )
        }
    }

    private func setPanelHeight(_ height: CGFloat, binding: Binding<CGFloat>) {
        let roundedHeight = ceil(height)
        guard roundedHeight > 0, abs(binding.wrappedValue - roundedHeight) > 0.5 else {
            return
        }

        DispatchQueue.main.async {
            withDisabledAnimation {
                binding.wrappedValue = roundedHeight
            }
        }
    }

    private var showsSplitTimerControls: Bool {
        if timer.timerMode == .pomodoro {
            return timer.isPomodoroActive
        }
        return timer.stopwatchPhase != .idle
    }

    private var splitPrimaryButtonLabel: String {
        if timer.timerMode == .pomodoro {
            return timer.isPomodoroPaused ? resumeLabel : pauseLabel
        }
        return timer.stopwatchPhase == .paused ? resumeLabel : pauseLabel
    }

    private func stopActiveTimer() {
        if timer.timerMode == .pomodoro {
            timer.stopPomodoro()
        } else {
            timer.stopStopwatch()
        }
    }

    private func primaryActionText(_ label: String) -> some View {
        Text(label)
            /*
              When appearance is set to "Dark" and accent color is set to "Graphite"
              "defaultAction" button label's color is set to the same color as the
              button, making the button look blank. #24
             */
            .foregroundColor(Color.white)
            .font(.system(.body).monospacedDigit())
            .frame(maxWidth: .infinity)
    }

    private var primaryButtonLabel: String {
        guard timer.timerMode == .stopwatch else {
            if !timer.isPomodoroActive {
                return startLabel
            }
            return timer.isPomodoroPaused ? resumeLabel : pauseLabel
        }

        switch timer.stopwatchPhase {
        case .idle:
            return startLabel
        case .running:
            return pauseLabel
        case .paused:
            return resumeLabel
        }
    }
}

private func durationString(_ durationSeconds: Int) -> String {
    let safeDurationSeconds = max(durationSeconds, 0)
    let seconds = safeDurationSeconds % 60
    let totalMinutes = safeDurationSeconds / 60
    let hours = totalMinutes / 60
    let remainingMinutes = totalMinutes % 60

    if safeDurationSeconds < 60 {
        return String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.duration.seconds", comment: "Seconds duration"),
            safeDurationSeconds
        )
    }

    if hours > 0 {
        return String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.duration.hoursMinutesSeconds", comment: "Hours, minutes, and seconds duration"),
            hours,
            remainingMinutes,
            seconds
        )
    }
    return String.localizedStringWithFormat(
        NSLocalizedString("HistoryView.duration.minutesSeconds", comment: "Minutes and seconds duration"),
        totalMinutes,
        seconds
    )
}

private func goalLabel(goalDurationSeconds: Int) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("HistoryView.dailyGoal.label", comment: "Daily focus goal label"),
        goalDurationString(goalDurationSeconds)
    )
}

private func goalProgressText(durationSeconds: Int, goalDurationSeconds: Int) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("HistoryView.goalProgress.percent", comment: "Daily goal progress percent"),
        goalProgressPercent(durationSeconds: durationSeconds, goalDurationSeconds: goalDurationSeconds)
    )
}

private func goalProgressSummary(durationSeconds: Int, goalDurationSeconds: Int) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("HistoryView.goalProgress.summary", comment: "Daily goal progress summary"),
        durationString(durationSeconds),
        goalDurationString(goalDurationSeconds),
        goalProgressPercent(durationSeconds: durationSeconds, goalDurationSeconds: goalDurationSeconds)
    )
}

private func goalDurationString(_ durationSeconds: Int) -> String {
    let safeDurationSeconds = max(durationSeconds, 0)
    if safeDurationSeconds < 60 {
        return String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.duration.seconds", comment: "Seconds duration"),
            safeDurationSeconds
        )
    }

    let minutes = safeDurationSeconds / 60
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours > 0 {
        return String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.duration.hoursMinutes", comment: "Hours and minutes duration"),
            hours,
            remainingMinutes
        )
    }
    return String.localizedStringWithFormat(
        NSLocalizedString("HistoryView.duration.minutes", comment: "Minutes duration"),
        minutes
    )
}

private func goalProgressPercent(durationSeconds: Int, goalDurationSeconds: Int) -> Int {
    Int((Double(durationSeconds) / Double(max(goalDurationSeconds, 1)) * 100).rounded())
}

private func timeRangeString(_ session: TBFocusSession) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return "\(formatter.string(from: session.startedAt)) - \(formatter.string(from: session.endedAt))"
}

private func sessionLabel(_ session: TBFocusSession) -> String {
    if session.mode == .stopwatch {
        return NSLocalizedString("HistoryView.session.stopwatch", comment: "Stopwatch focus session label")
    }

    let format = session.completed
        ? NSLocalizedString("HistoryView.session.completed", comment: "Completed session label")
        : NSLocalizedString("HistoryView.session.stopped", comment: "Stopped session label")
    return String.localizedStringWithFormat(format, session.focusIndexInSet, session.workIntervalsInSet)
}
