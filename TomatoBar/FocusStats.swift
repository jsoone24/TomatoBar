import Foundation

struct TBFocusPeriodStats: Equatable {
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
