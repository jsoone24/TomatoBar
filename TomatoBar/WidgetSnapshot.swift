import Foundation

enum TBWidgetSnapshotPhase: String, Codable, Equatable {
    case idle
    case focus
    case shortBreak
    case longBreak
    case paused
    case stopwatchRunning
    case stopwatchPaused
}

struct TBFocusPeriodStats: Codable, Equatable {
    let totalSeconds: Int
    let averageSeconds: Int
    let goalDays: Int
    let dayCount: Int

    init(totalSeconds: Int = 0,
         averageSeconds: Int = 0,
         goalDays: Int = 0,
         dayCount: Int = 0) {
        self.totalSeconds = max(totalSeconds, 0)
        self.averageSeconds = max(averageSeconds, 0)
        self.goalDays = max(goalDays, 0)
        self.dayCount = max(dayCount, 0)
    }

    init(dailyDurations: [Int], goalDurationSeconds: Int) {
        let dayCount = dailyDurations.count
        let totalSeconds = dailyDurations.reduce(0) { $0 + max($1, 0) }
        let safeGoalDurationSeconds = max(goalDurationSeconds, 1)
        self.init(
            totalSeconds: totalSeconds,
            averageSeconds: dayCount > 0 ? totalSeconds / dayCount : 0,
            goalDays: dailyDurations.filter { $0 >= safeGoalDurationSeconds }.count,
            dayCount: dayCount
        )
    }
}

struct TBWidgetSnapshot: Codable, Equatable {
    static let appGroupIdentifier = "group.com.jsoone24.TomatoBar"
    static let widgetKind = "TomatoBarFocusStatusWidget"

    let phase: TBWidgetSnapshotPhase
    let modeTitle: String
    let statusTitle: String
    let detailText: String
    let timeText: String
    let expectedEndAt: Date?
    let liveFocusStartedAt: Date?
    let liveFocusIncrementStartedAt: Date?
    let liveFocusIncrementEndedAt: Date?
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let completedFocusCount: Int
    let todayFocusSeconds: Int
    let dailyGoalSeconds: Int
    let weekStats: TBFocusPeriodStats
    let monthStats: TBFocusPeriodStats
    let updatedAt: Date

    static var placeholder: TBWidgetSnapshot {
        TBWidgetSnapshot(
            phase: .idle,
            modeTitle: "TomatoBar",
            statusTitle: "Ready",
            detailText: "Open TomatoBar to start focusing",
            timeText: "00:00",
            expectedEndAt: nil,
            liveFocusStartedAt: nil,
            liveFocusIncrementStartedAt: nil,
            liveFocusIncrementEndedAt: nil,
            focusIndexInSet: 1,
            workIntervalsInSet: 4,
            completedFocusCount: 0,
            todayFocusSeconds: 0,
            dailyGoalSeconds: 2 * 60 * 60,
            weekStats: TBFocusPeriodStats(),
            monthStats: TBFocusPeriodStats(),
            updatedAt: Date()
        )
    }

    var goalProgress: Double {
        Double(displayTodayFocusSeconds()) / Double(max(dailyGoalSeconds, 1))
    }

    var normalizedGoalProgress: Double {
        min(max(goalProgress, 0), 1)
    }

    func timeText(at date: Date = Date()) -> String {
        switch phase {
        case .focus, .shortBreak, .longBreak:
            guard let expectedEndAt else {
                return timeText
            }
            return TBFocusDurationFormatter.clockString(seconds: max(0, Int(expectedEndAt.timeIntervalSince(date))))
        case .stopwatchRunning:
            guard let liveFocusStartedAt else {
                return timeText
            }
            return TBFocusDurationFormatter.clockString(seconds: max(0, Int(date.timeIntervalSince(liveFocusStartedAt))))
        case .idle, .paused, .stopwatchPaused:
            return timeText
        }
    }

    func displayTodayFocusSeconds(at date: Date = Date(), calendar: Calendar = .current) -> Int {
        let safeStoredSeconds = max(todayFocusSeconds, 0)
        guard let liveFocusStartedAt,
              let liveFocusIncrementStartedAt else {
            return calendar.isDate(date, inSameDayAs: updatedAt) ? safeStoredSeconds : 0
        }

        let incrementEnd = min(date, liveFocusIncrementEndedAt ?? date)
        guard incrementEnd > liveFocusIncrementStartedAt else {
            return calendar.isDate(date, inSameDayAs: updatedAt) ? safeStoredSeconds : 0
        }

        if calendar.isDate(date, inSameDayAs: updatedAt) {
            return safeStoredSeconds + max(0, Int(incrementEnd.timeIntervalSince(liveFocusIncrementStartedAt)))
        }

        let dayStart = calendar.startOfDay(for: date)
        let overlapStart = max(liveFocusStartedAt, dayStart)
        return max(0, Int(incrementEnd.timeIntervalSince(overlapStart)))
    }

    func displayWeekStats(at date: Date = Date(), calendar: Calendar = .current) -> TBFocusPeriodStats {
        displayPeriodStats(weekStats, at: date, calendar: calendar)
    }

    func displayMonthStats(at date: Date = Date(), calendar: Calendar = .current) -> TBFocusPeriodStats {
        displayPeriodStats(monthStats, at: date, calendar: calendar)
    }

    private func displayPeriodStats(_ stats: TBFocusPeriodStats,
                                    at date: Date,
                                    calendar: Calendar) -> TBFocusPeriodStats {
        guard calendar.isDate(date, inSameDayAs: updatedAt) else {
            return stats
        }

        let currentTodayFocusSeconds = displayTodayFocusSeconds(at: date, calendar: calendar)
        let liveDeltaSeconds = max(0, currentTodayFocusSeconds - max(todayFocusSeconds, 0))
        guard liveDeltaSeconds > 0 else {
            return stats
        }

        let totalSeconds = stats.totalSeconds + liveDeltaSeconds
        let crossesGoal = todayFocusSeconds < dailyGoalSeconds && currentTodayFocusSeconds >= dailyGoalSeconds
        return TBFocusPeriodStats(
            totalSeconds: totalSeconds,
            averageSeconds: stats.dayCount > 0 ? totalSeconds / stats.dayCount : 0,
            goalDays: stats.goalDays + (crossesGoal ? 1 : 0),
            dayCount: stats.dayCount
        )
    }
}

enum TBFocusDurationFormatter {
    static func focusDurationString(_ durationSeconds: Int) -> String {
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

    static func goalDurationString(_ durationSeconds: Int) -> String {
        let safeDurationSeconds = max(durationSeconds, 0)
        if safeDurationSeconds < 60 {
            return focusDurationString(safeDurationSeconds)
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

    static func goalProgressText(durationSeconds: Int, goalDurationSeconds: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("HistoryView.goalProgress.percent", comment: "Daily goal progress percent"),
            Int((Double(max(durationSeconds, 0)) / Double(max(goalDurationSeconds, 1)) * 100).rounded())
        )
    }

    static func compactDurationString(_ durationSeconds: Int) -> String {
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

    static func clockString(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        let seconds = safeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum TBWidgetSnapshotStore {
    static func load() -> TBWidgetSnapshot {
        guard let fileURL = snapshotFileURL(),
              let data = try? Data(contentsOf: fileURL) else {
            return .placeholder
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TBWidgetSnapshot.self, from: data)) ?? .placeholder
    }

    static func save(_ snapshot: TBWidgetSnapshot) {
        guard let fileURL = snapshotFileURL() else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("cannot write widget snapshot: \(error)")
        }
    }

    private static func snapshotFileURL(fileManager: FileManager = .default) -> URL? {
        let directoryURL: URL
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: TBWidgetSnapshot.appGroupIdentifier) {
            directoryURL = appGroupURL
        } else {
            let baseURL = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? fileManager.temporaryDirectory
            directoryURL = baseURL.appendingPathComponent("TomatoBar", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return directoryURL.appendingPathComponent("WidgetSnapshot.json")
        } catch {
            print("cannot create widget snapshot directory: \(error)")
            return nil
        }
    }
}
