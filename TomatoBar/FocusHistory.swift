import Combine
import Foundation

enum TBApplicationStorage {
    static func supportDirectoryURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let supportURL = baseURL.appendingPathComponent("TomatoBar", isDirectory: true)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        return supportURL
    }
}

struct TBFocusSession: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let completed: Bool
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let plannedDurationSeconds: Int

    init(id: UUID = UUID(),
         startedAt: Date,
         endedAt: Date,
         durationSeconds: Int,
         completed: Bool,
         focusIndexInSet: Int,
         workIntervalsInSet: Int,
         plannedDurationSeconds: Int)
    {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.completed = completed
        self.focusIndexInSet = focusIndexInSet
        self.workIntervalsInSet = workIntervalsInSet
        self.plannedDurationSeconds = plannedDurationSeconds
    }
}

struct TBDailyFocusTotal: Identifiable, Equatable {
    let date: Date
    let durationSeconds: Int

    var id: Date { date }
}

class TBFocusHistoryStore: ObservableObject {
    @Published private(set) var sessions: [TBFocusSession] = []

    private let fileURL: URL
    private let calendar: Calendar
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.calendar = calendar
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        fileURL = TBApplicationStorage
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("FocusSessions.jsonl")

        load()
    }

    func record(startedAt: Date,
                endedAt: Date,
                completed: Bool,
                focusIndexInSet: Int,
                workIntervalsInSet: Int,
                plannedDurationSeconds: Int)
    {
        let duration = max(0, min(Int(endedAt.timeIntervalSince(startedAt)), plannedDurationSeconds))
        guard duration > 0 else {
            return
        }

        let session = TBFocusSession(
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            completed: completed,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            plannedDurationSeconds: plannedDurationSeconds
        )
        if append(session) {
            sessions.insert(session, at: 0)
        }
    }

    func totalFocusTime(on date: Date = Date()) -> Int {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return 0
        }

        return sessions
            .reduce(0) { $0 + overlapDuration(of: $1, from: dayStart, to: dayEnd) }
    }

    func recentSessions(limit: Int = 5) -> [TBFocusSession] {
        Array(sessions.prefix(limit))
    }

    func dailyTotals(endingAt date: Date = Date(), days: Int = 7) -> [TBDailyFocusTotal] {
        guard days > 0 else {
            return []
        }

        let endOfToday = calendar.startOfDay(for: date)
        return (0 ..< days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endOfToday) else {
                return nil
            }
            return TBDailyFocusTotal(
                date: day,
                durationSeconds: totalFocusTime(on: day)
            )
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            sessions = []
            return
        }

        sessions = content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(TBFocusSession.self, from: Data(line.utf8))
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func append(_ session: TBFocusSession) -> Bool {
        do {
            var data = try encoder.encode(session)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            return true
        } catch {
            print("cannot write focus session: \(error)")
            return false
        }
    }

    private func overlapDuration(of session: TBFocusSession, from rangeStart: Date, to rangeEnd: Date) -> Int {
        let start = max(session.startedAt, rangeStart)
        let end = min(session.endedAt, rangeEnd)
        return max(0, Int(end.timeIntervalSince(start)))
    }
}
