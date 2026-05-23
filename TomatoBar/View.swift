import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
}

private struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    private var minStr = NSLocalizedString("IntervalsView.min", comment: "min")

    var body: some View {
        VStack {
            Stepper(value: $timer.workIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalLength.label",
                                           comment: "Work interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.workIntervalLength))
                }
            }
            Stepper(value: $timer.shortRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.shortRestIntervalLength.label",
                                           comment: "Short rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.shortRestIntervalLength))
                }
            }
            Stepper(value: $timer.longRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.longRestIntervalLength.label",
                                           comment: "Long rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.longRestIntervalLength))
                }
            }
            .help(NSLocalizedString("IntervalsView.longRestIntervalLength.help",
                                    comment: "Long rest interval hint"))
            Stepper(value: $timer.workIntervalsInSet, in: 1 ... 10) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalsInSet.label",
                                           comment: "Work intervals in a set label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(timer.workIntervalsInSet)")
                }
            }
            .help(NSLocalizedString("IntervalsView.workIntervalsInSet.help",
                                    comment: "Work intervals in set hint"))
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable

    var body: some View {
        VStack {
            KeyboardShortcuts.Recorder(for: .startStopTimer) {
                Text(NSLocalizedString("SettingsView.shortcut.label",
                                       comment: "Shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: $timer.stopAfterBreak) {
                Text(NSLocalizedString("SettingsView.stopAfterBreak.label",
                                       comment: "Stop after break label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Toggle(isOn: $timer.showTimerInMenuBar) {
                Text(NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                       comment: "Show timer in menu bar label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
                .onChange(of: timer.showTimerInMenuBar) { _ in
                    timer.updateTimeLeft()
                }
            Toggle(isOn: $launchAtLogin.isEnabled) {
                Text(NSLocalizedString("SettingsView.launchAtLogin.label",
                                       comment: "Launch at login label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        Slider(value: $volume, in: 0...2) {
            Text(String(format: "%.1f", volume))
        }.gesture(TapGesture(count: 2).onEnded({
            volume = 1.0
        }))
    }
}

private struct SoundsView: View {
    @EnvironmentObject var player: TBPlayer

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(110))
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                   comment: "Windup label"))
            VolumeSlider(volume: $player.windupVolume)
            Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                   comment: "Ding label"))
            VolumeSlider(volume: $player.dingVolume)
            Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                   comment: "Ticking label"))
            VolumeSlider(volume: $player.tickingVolume)
        }.padding(4)
        Spacer().frame(minHeight: 0)
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
                Text(timer.timer != nil ? timer.timeLeftString : "--:--")
                    .font(.system(.title3).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            CycleDotsView().environmentObject(timer)
            Text(timer.nextStepDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
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

private struct WeekFocusBarsView: View {
    let totals: [TBDailyFocusTotal]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(totals) { total in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(total.durationSeconds > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: barHeight(for: total.durationSeconds))
                    Text(dayLabel(for: total.date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54)
    }

    private func barHeight(for durationSeconds: Int) -> CGFloat {
        let maxDuration = max(totals.map(\.durationSeconds).max() ?? 0, 1)
        return max(CGFloat(durationSeconds) / CGFloat(maxDuration) * 34, durationSeconds > 0 ? 6 : 3)
    }

    private func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return String(formatter.string(from: date).prefix(1))
    }
}

private struct HistoryView: View {
    @ObservedObject var history: TBFocusHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("HistoryView.today.label", comment: "Today label"))
                    .font(.headline)
                Spacer()
                Text(durationString(history.totalFocusTime()))
                    .font(.system(.headline).monospacedDigit())
            }

            WeekFocusBarsView(totals: history.dailyTotals())

            Divider()

            if history.recentSessions().isEmpty {
                Text(NSLocalizedString("HistoryView.empty.label", comment: "No focus sessions label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(history.recentSessions()) { session in
                    HistorySessionRow(session: session)
                }
            }
        }
        .padding(4)
    }
}

private struct HistorySessionRow: View {
    let session: TBFocusSession

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
        }
    }
}

private enum ChildView {
    case history, intervals, settings, sounds
}

struct TBPopoverView: View {
    @StateObject private var timer = TBTimer()
    @State private var activeChildView = ChildView.history

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

            Button {
                timer.startStop()
                if timer.timerMode == .pomodoro {
                    TBStatusItem.shared.closePopover(nil)
                }
            } label: {
                Text(primaryButtonLabel)
                    /*
                      When appearance is set to "Dark" and accent color is set to "Graphite"
                      "defaultAction" button label's color is set to the same color as the
                      button, making the button look blank. #24
                     */
                    .foregroundColor(Color.white)
                    .font(.system(.body).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .keyboardShortcut(.space, modifiers: [])

            if timer.timerMode == .stopwatch, timer.stopwatchPhase == .paused {
                Button {
                    timer.stopStopwatch()
                } label: {
                    Text(stopLabel)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }

            Picker("", selection: $activeChildView) {
                Text(NSLocalizedString("TBPopoverView.history.label",
                                       comment: "History label")).tag(ChildView.history)
                Text(NSLocalizedString("TBPopoverView.intervals.label",
                                       comment: "Intervals label")).tag(ChildView.intervals)
                Text(NSLocalizedString("TBPopoverView.settings.label",
                                       comment: "Settings label")).tag(ChildView.settings)
                Text(NSLocalizedString("TBPopoverView.sounds.label",
                                       comment: "Sounds label")).tag(ChildView.sounds)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .pickerStyle(.segmented)

            GroupBox {
                switch activeChildView {
                case .history:
                    HistoryView(history: timer.focusHistory)
                case .intervals:
                    IntervalsView().environmentObject(timer)
                case .settings:
                    SettingsView().environmentObject(timer)
                case .sounds:
                    SoundsView().environmentObject(timer.player)
                }
            }

            Group {
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
        }
        .padding(12)
    }

    private var primaryButtonLabel: String {
        guard timer.timerMode == .stopwatch else {
            return timer.timer != nil ? stopLabel : startLabel
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
    if durationSeconds < 60 {
        return String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.duration.seconds", comment: "Seconds duration"),
            durationSeconds
        )
    }

    let minutes = durationSeconds / 60
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
