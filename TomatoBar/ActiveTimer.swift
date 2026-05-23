import Combine
import Foundation

enum TBTimerMode: String, Codable, CaseIterable, Identifiable {
    case pomodoro, stopwatch

    var id: String { rawValue }
}

enum TBTimerPhase: String, Codable, Equatable {
    case idle, work, rest, workPaused, restPaused, stopwatchRunning, stopwatchPaused

    var isStopwatch: Bool {
        self == .stopwatchRunning || self == .stopwatchPaused
    }

    var isPausedPomodoro: Bool {
        self == .workPaused || self == .restPaused
    }
}

enum TBRestKind: String, Codable, Equatable {
    case short, long
}

enum TBStopwatchPhase: Equatable {
    case idle, running, paused
}

struct TBActiveTimerSnapshot: Codable, Equatable {
    let phase: TBTimerPhase
    let startedAt: Date?
    let expectedEndAt: Date?
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let restKind: TBRestKind?
    let revision: Int
    let updatedAt: Date
    let sessionID: UUID?
    let elapsedSeconds: Int?
    let runningStartedAt: Date?
    let pausedAt: Date?
    let completedWorkSets: Int?

    init(phase: TBTimerPhase,
         startedAt: Date?,
         expectedEndAt: Date?,
         focusIndexInSet: Int,
         workIntervalsInSet: Int,
         restKind: TBRestKind?,
         revision: Int,
         updatedAt: Date,
         sessionID: UUID?,
         elapsedSeconds: Int? = nil,
         runningStartedAt: Date? = nil,
         pausedAt: Date? = nil,
         completedWorkSets: Int? = nil) {
        self.phase = phase
        self.startedAt = startedAt
        self.expectedEndAt = expectedEndAt
        self.focusIndexInSet = focusIndexInSet
        self.workIntervalsInSet = workIntervalsInSet
        self.restKind = restKind
        self.revision = revision
        self.updatedAt = updatedAt
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
        self.runningStartedAt = runningStartedAt
        self.pausedAt = pausedAt
        self.completedWorkSets = completedWorkSets
    }
}

class TBActiveTimerStore: ObservableObject {
    @Published private(set) var snapshot: TBActiveTimerSnapshot?

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        fileURL = TBApplicationStorage
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("ActiveTimer.json")

        load()
    }

    func save(_ snapshot: TBActiveTimerSnapshot) {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            self.snapshot = snapshot
        } catch {
            print("cannot write active timer snapshot: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            snapshot = nil
            return
        }

        snapshot = try? decoder.decode(TBActiveTimerSnapshot.self, from: data)
    }
}
