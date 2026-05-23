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
    let sessionID: UUID?
    let sourceDeviceID: String?

    init(phase: TBTimerPhase,
         startedAt: Date?,
         expectedEndAt: Date?,
         focusIndexInSet: Int,
         workIntervalsInSet: Int,
         restKind: TBRestKind?,
         revision: Int,
         updatedAt: Date,
         sessionID: UUID?,
         sourceDeviceID: String?) {
        self.phase = phase
        self.startedAt = startedAt
        self.expectedEndAt = expectedEndAt
        self.focusIndexInSet = focusIndexInSet
        self.workIntervalsInSet = workIntervalsInSet
        self.restKind = restKind
        self.revision = revision
        self.updatedAt = updatedAt
        self.sessionID = sessionID
        self.sourceDeviceID = sourceDeviceID
    }
}

class TBActiveTimerStore: ObservableObject {
    @Published private(set) var snapshot: TBActiveTimerSnapshot?

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let syncStore: TBCloudKitSyncStore
    private var cancellables: Set<AnyCancellable> = []

    init(fileManager: FileManager = .default,
         syncStore: TBCloudKitSyncStore = .shared) {
        self.syncStore = syncStore
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        fileURL = TBApplicationStorage
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("ActiveTimer.json")

        load()
        bindSync()
    }

    func save(_ snapshot: TBActiveTimerSnapshot, sync: Bool = true) {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            self.snapshot = snapshot
            if sync {
                syncStore.save(activeTimer: snapshot)
            }
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

    private func bindSync() {
        syncStore.activeTimerSnapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self = self,
                      self.shouldAccept(snapshot) else {
                    return
                }
                self.save(snapshot, sync: false)
            }
            .store(in: &cancellables)
    }

    private func shouldAccept(_ incoming: TBActiveTimerSnapshot) -> Bool {
        guard let current = snapshot else {
            return true
        }
        if incoming.revision != current.revision {
            return incoming.revision > current.revision
        }
        return incoming.updatedAt > current.updatedAt
    }
}
