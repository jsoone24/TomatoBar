import SwiftUI
import WidgetKit

struct TBFocusWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TBWidgetSnapshot
}

struct TBFocusWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TBFocusWidgetEntry {
        TBFocusWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TBFocusWidgetEntry) -> Void) {
        completion(TBFocusWidgetEntry(date: Date(), snapshot: TBWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TBFocusWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = TBWidgetSnapshotStore.load()
        let entry = TBFocusWidgetEntry(date: now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
    }
}

struct FocusStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TBWidgetSnapshot.widgetKind, provider: TBFocusWidgetProvider()) { entry in
            FocusStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("TomatoBar Focus")
        .description("Shows your current focus state and daily progress.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TomatoBarWidgets: WidgetBundle {
    var body: some Widget {
        FocusStatusWidget()
    }
}

private struct FocusStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TBFocusWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumWidget
        default:
            smallWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            Text(entry.snapshot.statusTitle)
                .font(.headline)
                .lineLimit(1)
            Text(entry.snapshot.timeText(at: entry.date))
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 0)
            dailyProgressSummary
            periodStatsSummary
        }
        .padding()
        .widgetURL(URL(string: "tomatobar://open"))
    }

    private var mediumWidget: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                header
                Text(entry.snapshot.statusTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.snapshot.timeText(at: entry.date))
                    .font(.system(.title, design: .rounded).monospacedDigit())
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(entry.snapshot.detailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                cycleDots
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("HistoryView.today.label", comment: "Today label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(todayFocusText)
                    .font(.system(.headline).monospacedDigit())
                    .lineLimit(1)
                goalProgressBar
                Text(goalSummaryText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 3) {
                    periodStatsLine(
                        title: NSLocalizedString("HistoryView.stats.week", comment: "Week stats label"),
                        stats: currentWeekStats
                    )
                    periodStatsLine(
                        title: NSLocalizedString("HistoryView.stats.month", comment: "Month stats label"),
                        stats: currentMonthStats
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .widgetURL(URL(string: "tomatobar://open"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            Text(entry.snapshot.modeTitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private var periodStatsSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(periodStatsCompactLine(
                title: NSLocalizedString("HistoryView.stats.week", comment: "Week stats label"),
                stats: currentWeekStats
            ))
            Text(periodStatsCompactLine(
                title: NSLocalizedString("HistoryView.stats.month", comment: "Month stats label"),
                stats: currentMonthStats
            ))
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var dailyProgressSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(todayFocusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(progressText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            goalProgressBar
        }
    }

    private var cycleDots: some View {
        HStack(spacing: 5) {
            ForEach(1 ... max(entry.snapshot.workIntervalsInSet, 1), id: \.self) { index in
                Circle()
                    .fill(index <= entry.snapshot.completedFocusCount ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(index == entry.snapshot.focusIndexInSet ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            }
        }
    }

    private var goalProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * normalizedCurrentGoalProgress)
            }
        }
        .frame(height: 6)
    }

    private func periodStatsLine(title: String, stats: TBFocusPeriodStats) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundColor(.secondary)
            Text(TBFocusDurationFormatter.compactDurationString(stats.totalSeconds))
                .fontWeight(.semibold)
            Text("·")
                .foregroundColor(.secondary)
            Text("\(stats.goalDays)/\(stats.dayCount)")
                .font(.system(.caption2).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private func periodStatsCompactLine(title: String, stats: TBFocusPeriodStats) -> String {
        "\(title) \(TBFocusDurationFormatter.compactDurationString(stats.totalSeconds)) · \(stats.goalDays)/\(stats.dayCount)"
    }

    private var phaseColor: Color {
        switch entry.snapshot.phase {
        case .focus, .stopwatchRunning:
            return .accentColor
        case .shortBreak:
            return .green
        case .longBreak:
            return .blue
        case .paused, .stopwatchPaused:
            return .orange
        case .idle:
            return .secondary
        }
    }

    private var todayFocusText: String {
        TBFocusDurationFormatter.focusDurationString(currentTodayFocusSeconds)
    }

    private var progressText: String {
        TBFocusDurationFormatter.goalProgressText(
            durationSeconds: currentTodayFocusSeconds,
            goalDurationSeconds: entry.snapshot.dailyGoalSeconds
        )
    }

    private var goalSummaryText: String {
        String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.goalProgress.summary", comment: "Daily goal progress summary"),
            todayFocusText,
            TBFocusDurationFormatter.goalDurationString(entry.snapshot.dailyGoalSeconds),
            Int((Double(currentTodayFocusSeconds) / Double(max(entry.snapshot.dailyGoalSeconds, 1)) * 100).rounded())
        )
    }

    private var currentTodayFocusSeconds: Int {
        entry.snapshot.displayTodayFocusSeconds(at: entry.date)
    }

    private var currentWeekStats: TBFocusPeriodStats {
        entry.snapshot.displayWeekStats(at: entry.date)
    }

    private var currentMonthStats: TBFocusPeriodStats {
        entry.snapshot.displayMonthStats(at: entry.date)
    }

    private var normalizedCurrentGoalProgress: Double {
        min(max(Double(currentTodayFocusSeconds) / Double(max(entry.snapshot.dailyGoalSeconds, 1)), 0), 1)
    }
}
