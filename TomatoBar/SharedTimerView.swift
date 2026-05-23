import SwiftUI

struct TBSharedTimerView: View {
    @ObservedObject var timer: TBSharedTimerController

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")

    init(timer: TBSharedTimerController) {
        self.timer = timer
    }

    var body: some View {
        #if os(watchOS)
        watchBody
        #else
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(timer.statusTitle)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text(timer.timeLeftString)
                            .font(.system(.title2).monospacedDigit().weight(.medium))
                            .foregroundColor(.secondary)
                    }

                    TBSharedCycleDotsView(
                        total: timer.cycleTotal,
                        completed: timer.cycleCompletedCount,
                        active: timer.cycleActiveIndex
                    )

                    Text(timer.nextStepDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Button {
                    timer.startStop()
                } label: {
                    Text(timer.phase == .idle ? startLabel : stopLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if timer.phase == .rest {
                    Button {
                        timer.skipRest()
                    } label: {
                        Text(NSLocalizedString("TBTimer.onRestStart.skip.title", comment: "Skip"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("HistoryView.today.label", comment: "Today label"))
                            .font(.headline)
                        Spacer()
                        Text(sharedDurationString(timer.focusHistory.totalFocusTime()))
                            .font(.system(.headline).monospacedDigit())
                    }

                    TBSharedWeekFocusBarsView(totals: timer.focusHistory.dailyTotals())

                    ForEach(timer.focusHistory.recentSessions(limit: 4)) { session in
                        TBSharedSessionRow(session: session)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("TomatoBar")
        }
        #endif
    }

    #if os(watchOS)
    private var watchBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(timer.statusTitle)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(timer.timeLeftString)
                    .font(.system(.title2).monospacedDigit().weight(.semibold))

                TBSharedCycleDotsView(
                    total: timer.cycleTotal,
                    completed: timer.cycleCompletedCount,
                    active: timer.cycleActiveIndex
                )

                Text(timer.nextStepDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(timer.phase == .idle ? startLabel : stopLabel) {
                    timer.startStop()
                }

                if timer.phase == .rest {
                    Button(NSLocalizedString("TBTimer.onRestStart.skip.title", comment: "Skip")) {
                        timer.skipRest()
                    }
                    .font(.caption)
                }

                VStack(spacing: 2) {
                    Text(NSLocalizedString("HistoryView.today.label", comment: "Today label"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(sharedDurationString(timer.focusHistory.totalFocusTime()))
                        .font(.system(.caption).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
    #endif
}

private struct TBSharedCycleDotsView: View {
    let total: Int
    let completed: Int
    let active: Int?

    var body: some View {
        HStack(spacing: 7) {
            ForEach(1 ... max(total, 1), id: \.self) { index in
                Circle()
                    .fill(index <= completed ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(index == active ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
            }
        }
    }
}

private struct TBSharedWeekFocusBarsView: View {
    let totals: [TBDailyFocusTotal]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(totals) { total in
                VStack(spacing: 4) {
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
        .frame(height: 72)
    }

    private func barHeight(for durationSeconds: Int) -> CGFloat {
        let maxDuration = max(totals.map(\.durationSeconds).max() ?? 0, 1)
        return max(CGFloat(durationSeconds) / CGFloat(maxDuration) * 46, durationSeconds > 0 ? 8 : 4)
    }

    private func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return String(formatter.string(from: date).prefix(1))
    }
}

private struct TBSharedSessionRow: View {
    let session: TBFocusSession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sharedTimeRangeString(session))
                    .font(.caption)
                Text(sharedSessionLabel(session))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(sharedDurationString(session.durationSeconds))
                .font(.system(.caption).monospacedDigit())
                .foregroundColor(session.completed ? .primary : .secondary)
        }
    }
}

private func sharedDurationString(_ durationSeconds: Int) -> String {
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

private func sharedTimeRangeString(_ session: TBFocusSession) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return "\(formatter.string(from: session.startedAt)) - \(formatter.string(from: session.endedAt))"
}

private func sharedSessionLabel(_ session: TBFocusSession) -> String {
    let format = session.completed
        ? NSLocalizedString("HistoryView.session.completed", comment: "Completed session label")
        : NSLocalizedString("HistoryView.session.stopped", comment: "Stopped session label")
    return String.localizedStringWithFormat(format, session.focusIndexInSet, session.workIntervalsInSet)
}
