import Combine
import Foundation

enum TBTimerPhase: String, Codable, Equatable {
    case idle, work, rest
}

enum TBRestKind: String, Codable, Equatable {
    case short, long
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
