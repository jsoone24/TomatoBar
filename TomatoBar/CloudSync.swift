import CloudKit
import Combine
import Foundation

final class TBCloudKitSyncStore {
    static let shared = TBCloudKitSyncStore()

    let activeTimerSnapshots = PassthroughSubject<TBActiveTimerSnapshot, Never>()
    let focusSessions = PassthroughSubject<[TBFocusSession], Never>()

    private static let activeTimerRecordName = "current"
    private static let activeTimerRecordType = "ActiveTimer"
    private static let focusSessionRecordType = "FocusSession"
    private static let databaseSubscriptionID = "private-database-updates"

    private let database = CKContainer.default().privateCloudDatabase
    private let deviceID = TBDeviceIdentity.current
    private var pollingTimer: Timer?
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        installDatabaseSubscription()
        fetchActiveTimer()
        fetchFocusSessions()

        pollingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.fetchActiveTimer()
            self?.fetchFocusSessions()
        }
    }

    func save(activeTimer snapshot: TBActiveTimerSnapshot) {
        let recordID = CKRecord.ID(recordName: Self.activeTimerRecordName)
        database.fetch(withRecordID: recordID) { [weak self] record, _ in
            guard let self = self else {
                return
            }

            if let record = record,
               let serverSnapshot = TBActiveTimerSnapshot(record: record),
               serverSnapshot.isNewer(than: snapshot) {
                return
            }

            let record = record ?? CKRecord(recordType: Self.activeTimerRecordType, recordID: recordID)
            record["phase"] = snapshot.phase.rawValue as CKRecordValue
            record["startedAt"] = snapshot.startedAt as CKRecordValue?
            record["expectedEndAt"] = snapshot.expectedEndAt as CKRecordValue?
            record["focusIndexInSet"] = snapshot.focusIndexInSet as CKRecordValue
            record["workIntervalsInSet"] = snapshot.workIntervalsInSet as CKRecordValue
            record["restKind"] = snapshot.restKind?.rawValue as CKRecordValue?
            record["revision"] = snapshot.revision as CKRecordValue
            record["updatedAt"] = snapshot.updatedAt as CKRecordValue
            record["sessionID"] = snapshot.sessionID?.uuidString as CKRecordValue?
            record["sourceDeviceID"] = snapshot.sourceDeviceID as CKRecordValue?
            record["elapsedSeconds"] = snapshot.elapsedSeconds as CKRecordValue?
            record["runningStartedAt"] = snapshot.runningStartedAt as CKRecordValue?
            record["pausedAt"] = snapshot.pausedAt as CKRecordValue?

            self.database.save(record) { _, error in
                if let error = error {
                    print("cannot sync active timer: \(error)")
                }
            }
        }
    }

    func save(focusSession session: TBFocusSession) {
        let recordID = CKRecord.ID(recordName: session.id.uuidString)
        database.fetch(withRecordID: recordID) { [weak self] record, _ in
            guard let self = self else {
                return
            }

            if let record = record,
               let serverSession = TBFocusSession(record: record),
               serverSession != session {
                return
            }

            let record = record ?? CKRecord(recordType: Self.focusSessionRecordType, recordID: recordID)
            record["startedAt"] = session.startedAt as CKRecordValue
            record["endedAt"] = session.endedAt as CKRecordValue
            record["durationSeconds"] = session.durationSeconds as CKRecordValue
            record["completed"] = session.completed as CKRecordValue
            record["focusIndexInSet"] = session.focusIndexInSet as CKRecordValue
            record["workIntervalsInSet"] = session.workIntervalsInSet as CKRecordValue
            record["plannedDurationSeconds"] = session.plannedDurationSeconds as CKRecordValue
            record["mode"] = session.mode.rawValue as CKRecordValue

            self.database.save(record) { _, error in
                if let error = error {
                    print("cannot sync focus session: \(error)")
                }
            }
        }
    }

    func fetchActiveTimer() {
        database.fetch(withRecordID: CKRecord.ID(recordName: Self.activeTimerRecordName)) { [weak self] record, error in
            guard let self = self else {
                return
            }

            if let error = error as? CKError, error.code != .unknownItem {
                print("cannot fetch active timer: \(error)")
            }
            guard let record = record,
                  let snapshot = TBActiveTimerSnapshot(record: record),
                  snapshot.sourceDeviceID != self.deviceID else {
                return
            }

            DispatchQueue.main.async {
                self.activeTimerSnapshots.send(snapshot)
            }
        }
    }

    func fetchFocusSessions(limit: Int = 200) {
        fetchFocusSessions(cursor: nil, pendingSessions: [], limit: limit)
    }

    private func fetchFocusSessions(cursor: CKQueryOperation.Cursor?,
                                    pendingSessions: [TBFocusSession],
                                    limit: Int) {
        let query = CKQuery(
            recordType: Self.focusSessionRecordType,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

        let operation = cursor.map(CKQueryOperation.init(cursor:)) ?? CKQueryOperation(query: query)
        operation.resultsLimit = limit

        var sessions = pendingSessions
        operation.recordFetchedBlock = { record in
            guard let session = TBFocusSession(record: record) else {
                return
            }
            sessions.append(session)
        }
        operation.queryCompletionBlock = { [weak self] cursor, error in
            if let error = error {
                print("cannot fetch focus sessions: \(error)")
            }
            if let cursor = cursor {
                self?.fetchFocusSessions(cursor: cursor, pendingSessions: sessions, limit: limit)
                return
            }
            guard !sessions.isEmpty else {
                return
            }

            DispatchQueue.main.async {
                self?.focusSessions.send(sessions)
            }
        }

        database.add(operation)
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        guard notification?.notificationType == .database else {
            return
        }

        fetchActiveTimer()
        fetchFocusSessions()
    }

    private func installDatabaseSubscription() {
        let subscription = CKDatabaseSubscription(subscriptionID: Self.databaseSubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        database.save(subscription) { _, error in
            if let error = error as? CKError, error.code == .serverRejectedRequest {
                return
            }
            if let error = error {
                print("cannot install cloud sync subscription: \(error)")
            }
        }
    }
}

private extension TBActiveTimerSnapshot {
    func isNewer(than other: TBActiveTimerSnapshot) -> Bool {
        if revision != other.revision {
            return revision > other.revision
        }
        if updatedAt != other.updatedAt {
            return updatedAt > other.updatedAt
        }
        return (sourceDeviceID ?? "") > (other.sourceDeviceID ?? "")
    }
}

enum TBDeviceIdentity {
    private static let key = "deviceID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }

        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

private extension TBActiveTimerSnapshot {
    init?(record: CKRecord) {
        guard let phaseValue = record["phase"] as? String,
              let phase = TBTimerPhase(rawValue: phaseValue),
              let focusIndexInSet = record["focusIndexInSet"] as? Int,
              let workIntervalsInSet = record["workIntervalsInSet"] as? Int,
              let revision = record["revision"] as? Int,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }

        let restKind = (record["restKind"] as? String).flatMap(TBRestKind.init(rawValue:))
        let sessionID = (record["sessionID"] as? String).flatMap(UUID.init(uuidString:))

        self.init(
            phase: phase,
            startedAt: record["startedAt"] as? Date,
            expectedEndAt: record["expectedEndAt"] as? Date,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            restKind: restKind,
            revision: revision,
            updatedAt: updatedAt,
            sessionID: sessionID,
            sourceDeviceID: record["sourceDeviceID"] as? String,
            elapsedSeconds: record["elapsedSeconds"] as? Int,
            runningStartedAt: record["runningStartedAt"] as? Date,
            pausedAt: record["pausedAt"] as? Date
        )
    }
}

private extension TBFocusSession {
    init?(record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let startedAt = record["startedAt"] as? Date,
              let endedAt = record["endedAt"] as? Date,
              let durationSeconds = record["durationSeconds"] as? Int,
              let completed = record["completed"] as? Bool,
              let focusIndexInSet = record["focusIndexInSet"] as? Int,
              let workIntervalsInSet = record["workIntervalsInSet"] as? Int,
              let plannedDurationSeconds = record["plannedDurationSeconds"] as? Int else {
            return nil
        }
        let mode = (record["mode"] as? String).flatMap(TBTimerMode.init(rawValue:)) ?? .pomodoro

        self.init(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            completed: completed,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            plannedDurationSeconds: plannedDurationSeconds,
            mode: mode
        )
    }
}
