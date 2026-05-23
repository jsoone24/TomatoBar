import Combine
import Foundation
import SwiftUI

private struct TBSharedActiveFocusSession {
    let id: UUID
    let startedAt: Date
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let plannedDurationSeconds: Int
}

final class TBSharedTimerController: ObservableObject {
    @AppStorage("stopAfterBreak") var stopAfterBreak = false
    @AppStorage("workIntervalLength") var workIntervalLength = 25
    @AppStorage("shortRestIntervalLength") var shortRestIntervalLength = 5
    @AppStorage("longRestIntervalLength") var longRestIntervalLength = 15
    @AppStorage("workIntervalsInSet") var workIntervalsInSet = 4

    private static let timerModeKey = "timerMode"

    let focusHistory = TBFocusHistoryStore()
    let activeTimerStore = TBActiveTimerStore()

    @Published private(set) var timerMode: TBTimerMode = .pomodoro
    @Published private(set) var phase: TBTimerPhase = .idle
    @Published private(set) var timeLeftString = "--:--"
    @Published private(set) var activeRestKind: TBRestKind?
    @Published private(set) var consecutiveWorkIntervals = 0
    @Published private(set) var stopwatchPhase: TBStopwatchPhase = .idle
    @Published private(set) var stopwatchRestElapsedString = "00:00"

    private var activeFocusSession: TBSharedActiveFocusSession?
    private var activeTimerRevision = 0
    private var expectedEndAt: Date?
    private var isFollowingRemoteTimer = false
    private var tickTimer: Timer?
    private var stopwatchTickTimer: Timer?
    private var stopwatchSessionID: UUID?
    private var stopwatchStartedAt: Date?
    private var stopwatchRunningStartedAt: Date?
    private var stopwatchPausedAt: Date?
    private var stopwatchAccumulatedSeconds = 0
    private var cancellables: Set<AnyCancellable> = []
    private let formatter = DateComponentsFormatter()

    var statusTitle: String {
        if timerMode == .stopwatch {
            return stopwatchStatusTitle
        }

        switch phase {
        case .idle:
            return NSLocalizedString("TBTimer.status.idle", comment: "Idle timer status")
        case .work:
            return String.localizedStringWithFormat(
                NSLocalizedString("TBTimer.status.focus", comment: "Focus timer status"),
                currentFocusIndexInSet,
                safeWorkIntervalsInSet
            )
        case .rest:
            return activeRestKind == .long
                ? NSLocalizedString("TBTimer.status.longBreak", comment: "Long break timer status")
                : NSLocalizedString("TBTimer.status.shortBreak", comment: "Short break timer status")
        case .stopwatchRunning, .stopwatchPaused:
            return stopwatchStatusTitle
        }
    }

    var nextStepDescription: String {
        if timerMode == .stopwatch {
            return stopwatchDetailDescription
        }

        switch phase {
        case .idle:
            return String.localizedStringWithFormat(
                NSLocalizedString("TBTimer.next.focus", comment: "Next focus timer status"),
                1,
                safeWorkIntervalsInSet
            )
        case .work:
            if currentFocusIndexInSet >= safeWorkIntervalsInSet {
                return String.localizedStringWithFormat(
                    NSLocalizedString("TBTimer.next.longBreak", comment: "Next long break status"),
                    longRestIntervalLength
                )
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("TBTimer.next.shortBreak", comment: "Next short break status"),
                shortRestIntervalLength
            )
        case .rest:
            let nextFocusIndex = activeRestKind == .long ? 1 : min(consecutiveWorkIntervals + 1, safeWorkIntervalsInSet)
            return String.localizedStringWithFormat(
                NSLocalizedString("TBTimer.next.focus", comment: "Next focus timer status"),
                nextFocusIndex,
                safeWorkIntervalsInSet
            )
        case .stopwatchRunning, .stopwatchPaused:
            return stopwatchDetailDescription
        }
    }

    var cycleTotal: Int {
        safeWorkIntervalsInSet
    }

    var cycleCompletedCount: Int {
        switch phase {
        case .idle:
            return 0
        case .work:
            return min(consecutiveWorkIntervals, safeWorkIntervalsInSet)
        case .rest:
            return activeRestKind == .long ? safeWorkIntervalsInSet : min(consecutiveWorkIntervals, safeWorkIntervalsInSet)
        case .stopwatchRunning, .stopwatchPaused:
            return 0
        }
    }

    var cycleActiveIndex: Int? {
        phase == .work ? currentFocusIndexInSet : nil
    }

    var canChangeTimerMode: Bool {
        phase == .idle && stopwatchPhase == .idle
    }

    init() {
        timerMode = TBTimerMode(
            rawValue: UserDefaults.standard.string(forKey: Self.timerModeKey) ?? ""
        ) ?? .pomodoro
        if timerMode == .stopwatch {
            timeLeftString = "00:00"
        }

        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad

        activeTimerRevision = activeTimerStore.snapshot?.revision ?? 0
        bindActiveTimerSync()
        resumeActiveTimerIfNeeded()
    }

    func startStop() {
        if timerMode == .stopwatch {
            toggleStopwatch()
            return
        }

        switch phase {
        case .idle:
            startWork()
        case .work:
            finishActiveFocusSession(completed: false)
            enterIdle(publish: true)
        case .rest:
            enterIdle(publish: true)
        case .stopwatchRunning, .stopwatchPaused:
            toggleStopwatch()
        }
    }

    func setTimerMode(_ mode: TBTimerMode) {
        guard canChangeTimerMode, timerMode != mode else {
            return
        }
        timerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.timerModeKey)
        if mode == .stopwatch {
            resetStopwatch(publish: false, record: false)
        } else {
            timeLeftString = "--:--"
        }
    }

    func skipRest() {
        guard phase == .rest else {
            return
        }
        if activeRestKind == .long {
            consecutiveWorkIntervals = 0
        }
        startWork()
    }

    private var stopwatchStatusTitle: String {
        switch stopwatchPhase {
        case .idle:
            return NSLocalizedString("TBStopwatch.status.idle", comment: "Stopwatch idle status")
        case .running:
            return NSLocalizedString("TBStopwatch.status.running", comment: "Stopwatch running status")
        case .paused:
            return NSLocalizedString("TBStopwatch.status.paused", comment: "Stopwatch paused status")
        }
    }

    private var stopwatchDetailDescription: String {
        switch stopwatchPhase {
        case .idle:
            return NSLocalizedString("TBStopwatch.detail.idle", comment: "Stopwatch idle detail")
        case .running:
            return NSLocalizedString("TBStopwatch.detail.running", comment: "Stopwatch running detail")
        case .paused:
            return String.localizedStringWithFormat(
                NSLocalizedString("TBStopwatch.detail.paused", comment: "Stopwatch paused detail"),
                stopwatchRestElapsedString
            )
        }
    }

    private func toggleStopwatch() {
        switch stopwatchPhase {
        case .idle:
            startStopwatch()
        case .running:
            pauseStopwatch()
        case .paused:
            resumeStopwatch()
        }
    }

    func stopStopwatch() {
        guard stopwatchPhase != .idle else {
            return
        }
        resetStopwatch(publish: true, record: true)
    }

    private func startStopwatch() {
        let now = Date()
        stopwatchSessionID = UUID()
        stopwatchStartedAt = now
        stopwatchRunningStartedAt = now
        stopwatchPausedAt = nil
        stopwatchAccumulatedSeconds = 0
        stopwatchPhase = .running
        startStopwatchTicking()
        publishStopwatch(phase: .stopwatchRunning)
    }

    private func pauseStopwatch() {
        guard let runningStartedAt = stopwatchRunningStartedAt else {
            return
        }
        let now = Date()
        stopwatchAccumulatedSeconds += max(0, Int(now.timeIntervalSince(runningStartedAt)))
        stopwatchRunningStartedAt = nil
        stopwatchPausedAt = now
        stopwatchPhase = .paused
        updateStopwatchStrings()
        publishStopwatch(phase: .stopwatchPaused)
    }

    private func resumeStopwatch() {
        let now = Date()
        stopwatchRunningStartedAt = now
        stopwatchPausedAt = nil
        stopwatchPhase = .running
        startStopwatchTicking()
        publishStopwatch(phase: .stopwatchRunning)
    }

    private func resetStopwatch(publish: Bool, record: Bool) {
        let endedAt = stopwatchPausedAt ?? Date()
        let durationSeconds = currentStopwatchElapsedSeconds
        if record,
           let sessionID = stopwatchSessionID,
           let startedAt = stopwatchStartedAt {
            focusHistory.recordStopwatch(
                id: sessionID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds
            )
        }

        stopwatchTickTimer?.invalidate()
        stopwatchTickTimer = nil
        stopwatchPhase = .idle
        stopwatchSessionID = nil
        stopwatchStartedAt = nil
        stopwatchRunningStartedAt = nil
        stopwatchPausedAt = nil
        stopwatchAccumulatedSeconds = 0
        timeLeftString = timerMode == .stopwatch ? "00:00" : "--:--"
        stopwatchRestElapsedString = "00:00"

        if publish {
            publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)
        }
    }

    private func startWork() {
        let startedAt = Date()
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(workIntervalLength * 60))
        let focusIndexInSet = currentFocusIndexInSet
        phase = .work
        activeRestKind = nil
        isFollowingRemoteTimer = false
        activeFocusSession = TBSharedActiveFocusSession(
            id: UUID(),
            startedAt: startedAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: safeWorkIntervalsInSet,
            plannedDurationSeconds: workIntervalLength * 60
        )
        startTicking(until: expectedEndAt)
        publishActiveTimer(
            phase: .work,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet,
            restKind: nil,
            sessionID: activeFocusSession?.id
        )
    }

    private func startRest() {
        let isLongRest = consecutiveWorkIntervals >= safeWorkIntervalsInSet
        activeRestKind = isLongRest ? .long : .short
        let duration = (isLongRest ? longRestIntervalLength : shortRestIntervalLength) * 60
        let startedAt = Date()
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(duration))
        phase = .rest
        isFollowingRemoteTimer = false
        startTicking(until: expectedEndAt)
        publishActiveTimer(
            phase: .rest,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: min(consecutiveWorkIntervals, safeWorkIntervalsInSet),
            restKind: activeRestKind,
            sessionID: nil
        )
    }

    private func enterIdle(publish: Bool) {
        phase = .idle
        activeRestKind = nil
        activeFocusSession = nil
        isFollowingRemoteTimer = false
        consecutiveWorkIntervals = 0
        stopTicking()
        if publish {
            publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)
        }
    }

    private func handleTimerFinished() {
        switch phase {
        case .idle:
            stopTicking()
        case .work:
            finishActiveFocusSession(completed: true)
            consecutiveWorkIntervals += 1
            startRest()
        case .rest:
            let finishedLongRest = activeRestKind == .long
            activeRestKind = nil
            if stopAfterBreak {
                enterIdle(publish: true)
            } else {
                if finishedLongRest {
                    consecutiveWorkIntervals = 0
                }
                startWork()
            }
        case .stopwatchRunning, .stopwatchPaused:
            break
        }
    }

    private func finishActiveFocusSession(completed: Bool) {
        guard let activeFocusSession = activeFocusSession else {
            return
        }

        let plannedEnd = activeFocusSession.startedAt.addingTimeInterval(
            TimeInterval(activeFocusSession.plannedDurationSeconds)
        )
        let endedAt = completed ? plannedEnd : min(Date(), plannedEnd)
        focusHistory.record(
            id: activeFocusSession.id,
            startedAt: activeFocusSession.startedAt,
            endedAt: endedAt,
            completed: completed,
            focusIndexInSet: activeFocusSession.focusIndexInSet,
            workIntervalsInSet: activeFocusSession.workIntervalsInSet,
            plannedDurationSeconds: activeFocusSession.plannedDurationSeconds
        )
        self.activeFocusSession = nil
    }

    private func startTicking(until expectedEndAt: Date) {
        self.expectedEndAt = expectedEndAt
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        expectedEndAt = nil
        timeLeftString = "--:--"
    }

    private func tick() {
        guard let expectedEndAt = expectedEndAt else {
            timeLeftString = "--:--"
            return
        }

        let timeLeft = expectedEndAt.timeIntervalSinceNow
        timeLeftString = formatter.string(from: max(timeLeft, 0)) ?? "00:00"
        if timeLeft <= 0 {
            if isFollowingRemoteTimer {
                stopTicking()
                return
            }
            handleTimerFinished()
        }
    }

    private func startStopwatchTicking() {
        stopwatchTickTimer?.invalidate()
        stopwatchTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateStopwatchStrings()
        }
        updateStopwatchStrings()
    }

    private func updateStopwatchStrings() {
        timeLeftString = Self.clockString(seconds: currentStopwatchElapsedSeconds)
        if let pausedAt = stopwatchPausedAt {
            stopwatchRestElapsedString = Self.clockString(seconds: max(0, Int(Date().timeIntervalSince(pausedAt))))
        } else {
            stopwatchRestElapsedString = "00:00"
        }
    }

    private var currentStopwatchElapsedSeconds: Int {
        guard stopwatchPhase == .running,
              let runningStartedAt = stopwatchRunningStartedAt else {
            return stopwatchAccumulatedSeconds
        }
        return stopwatchAccumulatedSeconds + max(0, Int(Date().timeIntervalSince(runningStartedAt)))
    }

    private static func clockString(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        let seconds = safeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func bindActiveTimerSync() {
        activeTimerStore.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard snapshot.sourceDeviceID != TBDeviceIdentity.current else {
                    return
                }
                self?.apply(snapshot)
            }
            .store(in: &cancellables)
    }

    private func resumeActiveTimerIfNeeded() {
        guard let snapshot = activeTimerStore.snapshot,
              snapshot.phase != .idle else {
            return
        }
        if snapshot.phase.isStopwatch {
            apply(snapshot)
            return
        }
        guard snapshot.expectedEndAt ?? Date() > Date() else {
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: TBActiveTimerSnapshot) {
        activeTimerRevision = max(activeTimerRevision, snapshot.revision)
        switch snapshot.phase {
        case .idle:
            enterIdle(publish: false)
            resetStopwatch(publish: false, record: false)
        case .work:
            timerMode = .pomodoro
            UserDefaults.standard.set(timerMode.rawValue, forKey: Self.timerModeKey)
            resetStopwatch(publish: false, record: false)
            let startedAt = snapshot.startedAt ?? Date()
            let expectedEndAt = snapshot.expectedEndAt ?? startedAt.addingTimeInterval(TimeInterval(workIntervalLength * 60))
            let focusIndexInSet = max(snapshot.focusIndexInSet, 1)
            phase = .work
            activeRestKind = nil
            isFollowingRemoteTimer = snapshot.sourceDeviceID != TBDeviceIdentity.current
            consecutiveWorkIntervals = max(0, min(focusIndexInSet - 1, safeWorkIntervalsInSet - 1))
            activeFocusSession = TBSharedActiveFocusSession(
                id: snapshot.sessionID ?? UUID(),
                startedAt: startedAt,
                focusIndexInSet: focusIndexInSet,
                workIntervalsInSet: max(snapshot.workIntervalsInSet, 1),
                plannedDurationSeconds: max(1, Int(expectedEndAt.timeIntervalSince(startedAt)))
            )
            startTicking(until: expectedEndAt)
        case .rest:
            timerMode = .pomodoro
            UserDefaults.standard.set(timerMode.rawValue, forKey: Self.timerModeKey)
            resetStopwatch(publish: false, record: false)
            let startedAt = snapshot.startedAt ?? Date()
            let expectedEndAt = snapshot.expectedEndAt ?? startedAt.addingTimeInterval(TimeInterval(shortRestIntervalLength * 60))
            phase = .rest
            activeRestKind = snapshot.restKind ?? .short
            isFollowingRemoteTimer = snapshot.sourceDeviceID != TBDeviceIdentity.current
            consecutiveWorkIntervals = min(max(snapshot.focusIndexInSet, 0), max(snapshot.workIntervalsInSet, 1))
            activeFocusSession = nil
            startTicking(until: expectedEndAt)
        case .stopwatchRunning, .stopwatchPaused:
            enterIdle(publish: false)
            configureStopwatch(from: snapshot)
        }
    }

    private func publishActiveTimer(phase: TBTimerPhase,
                                    startedAt: Date?,
                                    expectedEndAt: Date?,
                                    focusIndexInSet: Int = 0,
                                    restKind: TBRestKind? = nil,
                                    sessionID: UUID? = nil) {
        activeTimerRevision += 1
        activeTimerStore.save(TBActiveTimerSnapshot(
            phase: phase,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: safeWorkIntervalsInSet,
            restKind: restKind,
            revision: activeTimerRevision,
            updatedAt: Date(),
            sessionID: sessionID,
            sourceDeviceID: TBDeviceIdentity.current
        ))
    }

    private func publishStopwatch(phase: TBTimerPhase) {
        activeTimerRevision += 1
        activeTimerStore.save(TBActiveTimerSnapshot(
            phase: phase,
            startedAt: stopwatchStartedAt,
            expectedEndAt: nil,
            focusIndexInSet: 0,
            workIntervalsInSet: 0,
            restKind: nil,
            revision: activeTimerRevision,
            updatedAt: Date(),
            sessionID: stopwatchSessionID,
            sourceDeviceID: TBDeviceIdentity.current,
            elapsedSeconds: stopwatchAccumulatedSeconds,
            runningStartedAt: stopwatchRunningStartedAt,
            pausedAt: stopwatchPausedAt
        ))
    }

    private func configureStopwatch(from snapshot: TBActiveTimerSnapshot) {
        timerMode = .stopwatch
        UserDefaults.standard.set(timerMode.rawValue, forKey: Self.timerModeKey)
        stopwatchSessionID = snapshot.sessionID ?? UUID()
        stopwatchStartedAt = snapshot.startedAt ?? Date()
        stopwatchAccumulatedSeconds = max(0, snapshot.elapsedSeconds ?? 0)
        stopwatchRunningStartedAt = snapshot.runningStartedAt
        stopwatchPausedAt = snapshot.pausedAt
        stopwatchPhase = snapshot.phase == .stopwatchRunning ? .running : .paused
        if stopwatchPhase == .running, stopwatchRunningStartedAt == nil {
            stopwatchRunningStartedAt = snapshot.updatedAt
        }
        if stopwatchPhase == .paused, stopwatchPausedAt == nil {
            stopwatchPausedAt = snapshot.updatedAt
        }
        startStopwatchTicking()
        updateStopwatchStrings()
    }

    private var currentFocusIndexInSet: Int {
        min(max(consecutiveWorkIntervals + (phase == .work ? 1 : 0), 1), safeWorkIntervalsInSet)
    }

    private var safeWorkIntervalsInSet: Int {
        max(workIntervalsInSet, 1)
    }
}
