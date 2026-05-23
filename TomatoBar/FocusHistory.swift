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
    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case endedAt
        case durationSeconds
        case completed
        case focusIndexInSet
        case workIntervalsInSet
        case plannedDurationSeconds
        case mode
    }

    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let completed: Bool
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let plannedDurationSeconds: Int
    let mode: TBTimerMode

    init(id: UUID = UUID(),
         startedAt: Date,
         endedAt: Date,
         durationSeconds: Int,
         completed: Bool,
         focusIndexInSet: Int,
         workIntervalsInSet: Int,
         plannedDurationSeconds: Int,
         mode: TBTimerMode = .pomodoro)
    {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.completed = completed
        self.focusIndexInSet = focusIndexInSet
        self.workIntervalsInSet = workIntervalsInSet
        self.plannedDurationSeconds = plannedDurationSeconds
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        completed = try container.decode(Bool.self, forKey: .completed)
        focusIndexInSet = try container.decode(Int.self, forKey: .focusIndexInSet)
        workIntervalsInSet = try container.decode(Int.self, forKey: .workIntervalsInSet)
        plannedDurationSeconds = try container.decode(Int.self, forKey: .plannedDurationSeconds)
        mode = try container.decodeIfPresent(TBTimerMode.self, forKey: .mode) ?? .pomodoro
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
    private let syncStore: TBCloudKitSyncStore
    private var cancellables: Set<AnyCancellable> = []

    init(fileManager: FileManager = .default,
         calendar: Calendar = .current,
         syncStore: TBCloudKitSyncStore = .shared) {
        self.calendar = calendar
        self.syncStore = syncStore
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        fileURL = TBApplicationStorage
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("FocusSessions.jsonl")

        load()
        bindSync()
    }

    func record(id: UUID = UUID(),
                startedAt: Date,
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
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            completed: completed,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            plannedDurationSeconds: plannedDurationSeconds
        )
        save(session, sync: true)
    }

    func recordStopwatch(id: UUID = UUID(),
                         startedAt: Date,
                         endedAt: Date,
                         durationSeconds: Int)
    {
        let duration = max(0, durationSeconds)
        guard duration > 0 else {
            return
        }

        let session = TBFocusSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            completed: true,
            focusIndexInSet: 1,
            workIntervalsInSet: 1,
            plannedDurationSeconds: duration,
            mode: .stopwatch
        )
        save(session, sync: true)
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

        let loadedSessions = content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(TBFocusSession.self, from: Data(line.utf8))
            }
            .sorted { $0.startedAt > $1.startedAt }
        sessions = loadedSessions.reduce(into: []) { partialResult, session in
            guard !partialResult.contains(where: { $0.id == session.id }) else {
                return
            }
            partialResult.append(session)
        }
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

    private func save(_ session: TBFocusSession, sync: Bool) {
        let updatesExistingSession = sessions.contains { $0.id == session.id }
        guard upsert(session) else {
            return
        }

        sortSessions()
        if updatesExistingSession {
            persist()
        } else if !append(session) {
            return
        }

        if sync {
            syncStore.save(focusSession: session)
        }
    }

    private func merge(_ remoteSessions: [TBFocusSession]) {
        guard remoteSessions.reduce(false, { upsert($1) || $0 }) else {
            return
        }

        sortSessions()
        persist()
    }

    private func upsert(_ session: TBFocusSession) -> Bool {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard sessions[index] != session else {
                return false
            }
            print("conflicting focus session ignored: \(session.id.uuidString)")
            return false
        }

        sessions.append(session)
        return true
    }

    private func persist() {
        do {
            var data = Data()
            for session in sessions {
                data.append(try encoder.encode(session))
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("cannot write focus sessions: \(error)")
        }
    }

    private func bindSync() {
        syncStore.focusSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.merge(sessions)
            }
            .store(in: &cancellables)
    }

    private func sortSessions() {
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    private func overlapDuration(of session: TBFocusSession, from rangeStart: Date, to rangeEnd: Date) -> Int {
        let start = max(session.startedAt, rangeStart)
        let end = min(session.endedAt, rangeEnd)
        return max(0, Int(end.timeIntervalSince(start)))
    }
}
