import Combine
import KeyboardShortcuts
import SwiftState
import SwiftUI

private struct TBActiveFocusSession {
    let id: UUID
    let startedAt: Date
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let plannedDurationSeconds: Int
}

class TBTimer: ObservableObject {
    private static let timerModeKey = "timerMode"

    @AppStorage("stopAfterBreak") var stopAfterBreak = false
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true
    @AppStorage("workIntervalLength") var workIntervalLength = 25
    @AppStorage("shortRestIntervalLength") var shortRestIntervalLength = 5
    @AppStorage("longRestIntervalLength") var longRestIntervalLength = 15
    @AppStorage("workIntervalsInSet") var workIntervalsInSet = 4
    // This preference is "hidden"
    @AppStorage("overrunTimeLimit") var overrunTimeLimit = -60.0

    private var stateMachine = TBStateMachine(state: .idle)
    public let player = TBPlayer()
    public let focusHistory = TBFocusHistoryStore()
    public let activeTimerStore = TBActiveTimerStore()
    @Published private(set) var timerMode: TBTimerMode = .pomodoro
    @Published private var consecutiveWorkIntervals: Int = 0
    @Published private var activeRestKind: TBRestKind?
    @Published private(set) var stopwatchPhase: TBStopwatchPhase = .idle
    @Published private(set) var stopwatchRestElapsedString = "00:00"
    private var activeFocusSession: TBActiveFocusSession?
    private var activeTimerRevision: Int = 0
    private var notificationCenter = TBNotificationCenter()
    private var finishTime: Date?
    private var stopwatchSessionID: UUID?
    private var stopwatchStartedAt: Date?
    private var stopwatchRunningStartedAt: Date?
    private var stopwatchPausedAt: Date?
    private var stopwatchAccumulatedSeconds = 0
    private var stopwatchTickTimer: DispatchSourceTimer?
    private var timerFormatter = DateComponentsFormatter()
    @Published var timeLeftString: String = ""
    @Published var timer: DispatchSourceTimer?

    var statusTitle: String {
        if timerMode == .stopwatch {
            return stopwatchStatusTitle
        }

        switch stateMachine.state {
        case .idle:
            return NSLocalizedString("TBTimer.status.idle", comment: "Idle timer status")
        case .work:
            return String.localizedStringWithFormat(
                NSLocalizedString("TBTimer.status.focus", comment: "Focus timer status"),
                currentFocusIndexInSet,
                safeWorkIntervalsInSet
            )
        case .rest:
            if activeRestKind == .long {
                return NSLocalizedString("TBTimer.status.longBreak", comment: "Long break timer status")
            }
            return NSLocalizedString("TBTimer.status.shortBreak", comment: "Short break timer status")
        }
    }

    var nextStepDescription: String {
        if timerMode == .stopwatch {
            return stopwatchDetailDescription
        }

        switch stateMachine.state {
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
        }
    }

    var cycleTotal: Int {
        safeWorkIntervalsInSet
    }

    var cycleCompletedCount: Int {
        switch stateMachine.state {
        case .idle:
            return 0
        case .work:
            return min(consecutiveWorkIntervals, safeWorkIntervalsInSet)
        case .rest:
            return activeRestKind == .long ? safeWorkIntervalsInSet : min(consecutiveWorkIntervals, safeWorkIntervalsInSet)
        }
    }

    var cycleActiveIndex: Int? {
        guard stateMachine.state == .work else {
            return nil
        }
        return currentFocusIndexInSet
    }

    var canChangeTimerMode: Bool {
        stateMachine.state == .idle && stopwatchPhase == .idle
    }

    private var currentFocusIndexInSet: Int {
        min(max(consecutiveWorkIntervals + (stateMachine.state == .work ? 1 : 0), 1), safeWorkIntervalsInSet)
    }

    private var safeWorkIntervalsInSet: Int {
        max(workIntervalsInSet, 1)
    }

    init() {
        timerMode = TBTimerMode(
            rawValue: UserDefaults.standard.string(forKey: Self.timerModeKey) ?? ""
        ) ?? .pomodoro
        if timerMode == .stopwatch {
            timeLeftString = "00:00"
        }

        /*
         * State diagram
         *
         *                 start/stop
         *       +--------------+-------------+
         *       |              |             |
         *       |  start/stop  |  timerFired |
         *       V    |         |    |        |
         * +--------+ |  +--------+  | +--------+
         * | idle   |--->| work   |--->| rest   |
         * +--------+    +--------+    +--------+
         *   A                  A        |    |
         *   |                  |        |    |
         *   |                  +--------+    |
         *   |  timerFired (!stopAfterBreak)  |
         *   |             skipRest           |
         *   |                                |
         *   +--------------------------------+
         *      timerFired (stopAfterBreak)
         *
         */
        stateMachine.addRoutes(event: .startStop, transitions: [
            .idle => .work, .work => .idle, .rest => .idle,
        ])
        stateMachine.addRoutes(event: .timerFired, transitions: [.work => .rest])
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .idle]) { _ in
            self.stopAfterBreak
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .work]) { _ in
            !self.stopAfterBreak
        }
        stateMachine.addRoutes(event: .skipRest, transitions: [.rest => .work])
        stateMachine.addRoute(.idle => .rest)
        stateMachine.addRoute(.rest => .work)

        /*
         * "Finish" handlers are called when time interval ended
         * "End"    handlers are called when time interval ended or was cancelled
         */
        stateMachine.addAnyHandler(.any => .work, handler: onWorkStart)
        stateMachine.addAnyHandler(.work => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.any => .rest, handler: onRestStart)
        stateMachine.addAnyHandler(.rest => .work, handler: onRestFinish)
        stateMachine.addAnyHandler(.any => .idle, handler: onIdleStart)
        stateMachine.addAnyHandler(.any => .any, handler: { ctx in
            logger.append(event: TBLogEventTransition(fromContext: ctx))
        })

        stateMachine.addErrorHandler { ctx in fatalError("state machine context: <\(ctx)>") }

        timerFormatter.unitsStyle = .positional
        timerFormatter.allowedUnits = [.minute, .second]
        timerFormatter.zeroFormattingBehavior = .pad

        activeTimerRevision = activeTimerStore.snapshot?.revision ?? 0
        resumeActiveTimerIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .startStopTimer, action: startStop)
        notificationCenter.setActionHandler(handler: onNotificationAction)

        let aem: NSAppleEventManager = NSAppleEventManager.shared()
        aem.setEventHandler(self,
                            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
                            forEventClass: AEEventClass(kInternetEventClass),
                            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                 withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.forKeyword(AEKeyword(keyDirectObject))?.stringValue else {
            print("url handling error: cannot get url")
            return
        }
        let url = URL(string: urlString)
        guard url != nil,
              let scheme = url!.scheme,
              let host = url!.host else {
            print("url handling error: cannot parse url")
            return
        }
        guard scheme.caseInsensitiveCompare("tomatobar") == .orderedSame else {
            print("url handling error: unknown scheme \(scheme)")
            return
        }
        switch host.lowercased() {
        case "startstop":
            startStop()
        default:
            print("url handling error: unknown command \(host)")
            return
        }
    }

    func startStop() {
        if timerMode == .stopwatch {
            toggleStopwatch()
            return
        }

        stateMachine <-! .startStop
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
            timeLeftString = ""
            TBStatusItem.shared.setTitle(title: nil)
        }
    }

    func skipRest() {
        stateMachine <-! .skipRest
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
        TBStatusItem.shared.setIcon(name: .work)
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
        TBStatusItem.shared.setIcon(name: .idle)
        updateStopwatchStrings()
        publishStopwatch(phase: .stopwatchPaused)
    }

    private func resumeStopwatch() {
        let now = Date()
        stopwatchRunningStartedAt = now
        stopwatchPausedAt = nil
        stopwatchPhase = .running
        TBStatusItem.shared.setIcon(name: .work)
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

        stopStopwatchTicking()
        stopwatchPhase = .idle
        stopwatchSessionID = nil
        stopwatchStartedAt = nil
        stopwatchRunningStartedAt = nil
        stopwatchPausedAt = nil
        stopwatchAccumulatedSeconds = 0
        stopwatchRestElapsedString = "00:00"
        timeLeftString = timerMode == .stopwatch ? "00:00" : ""
        TBStatusItem.shared.setIcon(name: .idle)
        TBStatusItem.shared.setTitle(title: nil)

        if publish {
            publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)
        }
    }

    func updateTimeLeft() {
        if timerMode == .stopwatch, stopwatchPhase != .idle {
            updateStopwatchStrings()
            return
        }

        guard let finishTime = finishTime, timer != nil else {
            timeLeftString = ""
            TBStatusItem.shared.setTitle(title: nil)
            return
        }

        let timeLeft = max(finishTime.timeIntervalSinceNow, 0)
        timeLeftString = timerFormatter.string(from: timeLeft) ?? "00:00"
        TBStatusItem.shared.setTitle(title: showTimerInMenuBar ? timeLeftString : nil)
    }

    @discardableResult
    private func startTimer(seconds: Int, startedAt: Date = Date()) -> Date {
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(seconds))
        startTimer(until: expectedEndAt)
        return expectedEndAt
    }

    private func startTimer(until expectedEndAt: Date) {
        stopTimer()
        finishTime = expectedEndAt

        let queue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer!.setEventHandler(handler: onTimerTick)
        timer!.setCancelHandler(handler: onTimerCancel)
        timer!.resume()
        updateTimeLeft()
    }

    private func stopTimer() {
        let currentTimer = timer
        timer = nil
        finishTime = nil
        currentTimer?.cancel()
        updateTimeLeft()
    }

    private func onTimerTick() {
        /* Cannot publish updates from background thread */
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
            guard let finishTime = finishTime else {
                return
            }
            let timeLeft = finishTime.timeIntervalSince(Date())
            if timeLeft <= 0 {
                /*
                 Ticks can be missed during the machine sleep.
                 Stop the timer if it goes beyond an overrun time limit.
                 */
                if timeLeft < overrunTimeLimit {
                    stateMachine <-! .startStop
                } else {
                    stateMachine <-! .timerFired
                }
            }
        }
    }

    private func onTimerCancel() {
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
        }
    }

    private func startStopwatchTicking() {
        stopStopwatchTicking()
        stopwatchTickTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        stopwatchTickTimer?.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        stopwatchTickTimer?.setEventHandler { [weak self] in
            self?.updateStopwatchStrings()
        }
        stopwatchTickTimer?.resume()
        updateStopwatchStrings()
    }

    private func stopStopwatchTicking() {
        let currentTimer = stopwatchTickTimer
        stopwatchTickTimer = nil
        currentTimer?.cancel()
    }

    private func updateStopwatchStrings() {
        timeLeftString = Self.clockString(seconds: currentStopwatchElapsedSeconds)
        if let pausedAt = stopwatchPausedAt {
            stopwatchRestElapsedString = Self.clockString(seconds: max(0, Int(Date().timeIntervalSince(pausedAt))))
        } else {
            stopwatchRestElapsedString = "00:00"
        }

        TBStatusItem.shared.setTitle(title: showTimerInMenuBar ? timeLeftString : nil)
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

    private func onNotificationAction(action: TBNotification.Action) {
        if action == .skipRest, stateMachine.state == .rest {
            skipRest()
        }
    }

    private func onWorkStart(context ctx: TBStateMachine.Context) {
        if let snapshot = snapshot(from: ctx) {
            configureWork(from: snapshot)
            return
        }

        let plannedDurationSeconds = workIntervalLength * 60
        let startedAt = Date()
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(plannedDurationSeconds))
        let focusIndexInSet = currentFocusIndexInSet
        configureWork(
            sessionID: UUID(),
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: safeWorkIntervalsInSet
        )
        player.playWindup()
        publishActiveTimer(
            phase: .work,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet,
            sessionID: activeFocusSession?.id
        )
    }

    private func onWorkFinish(context ctx: TBStateMachine.Context) {
        guard snapshot(from: ctx) == nil else {
            return
        }
        finishActiveFocusSession(completed: true)
        consecutiveWorkIntervals += 1
        player.playDing()
    }

    private func onWorkEnd(context ctx: TBStateMachine.Context) {
        if ctx.toState == .idle, snapshot(from: ctx) == nil {
            finishActiveFocusSession(completed: false)
        }
        player.stopTicking()
    }

    private func onRestStart(context ctx: TBStateMachine.Context) {
        if let snapshot = snapshot(from: ctx) {
            configureRest(from: snapshot)
            return
        }

        var body = NSLocalizedString("TBTimer.onRestStart.short.body", comment: "Short break body")
        var length = shortRestIntervalLength
        var imgName = NSImage.Name.shortRest
        if consecutiveWorkIntervals >= safeWorkIntervalsInSet {
            activeRestKind = .long
            body = NSLocalizedString("TBTimer.onRestStart.long.body", comment: "Long break body")
            length = longRestIntervalLength
            imgName = .longRest
        } else {
            activeRestKind = .short
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Time's up title"),
            body: body,
            category: .restStarted
        )
        TBStatusItem.shared.setIcon(name: imgName)
        let startedAt = Date()
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(length * 60))
        startTimer(until: expectedEndAt)
        publishActiveTimer(
            phase: .rest,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: min(consecutiveWorkIntervals, safeWorkIntervalsInSet),
            restKind: activeRestKind,
            sessionID: nil
        )
    }

    private func onRestFinish(context ctx: TBStateMachine.Context) {
        let finishedLongRest = activeRestKind == .long
        activeRestKind = nil
        if finishedLongRest {
            consecutiveWorkIntervals = 0
        }
        if ctx.event == .skipRest || snapshot(from: ctx) != nil {
            return
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Break is over title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Break is over body"),
            category: .restFinished
        )
    }

    private func onIdleStart(context ctx: TBStateMachine.Context) {
        if ctx.fromState == .work, snapshot(from: ctx) == nil {
            finishActiveFocusSession(completed: false)
        }
        stopTimer()
        TBStatusItem.shared.setIcon(name: .idle)
        activeRestKind = nil
        activeFocusSession = nil
        consecutiveWorkIntervals = 0
        if snapshot(from: ctx) == nil {
            publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)
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
            sessionID: sessionID
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
            elapsedSeconds: stopwatchAccumulatedSeconds,
            runningStartedAt: stopwatchRunningStartedAt,
            pausedAt: stopwatchPausedAt
        ))
    }

    private func resumeActiveTimerIfNeeded() {
        guard let snapshot = activeTimerStore.snapshot,
              snapshot.phase != .idle else {
            return
        }
        if snapshot.phase.isStopwatch {
            applyActiveTimerSnapshot(snapshot)
            return
        }
        guard snapshot.expectedEndAt ?? Date() > Date() else {
            return
        }

        applyActiveTimerSnapshot(snapshot)
    }

    private func applyActiveTimerSnapshot(_ snapshot: TBActiveTimerSnapshot) {
        activeTimerRevision = max(activeTimerRevision, snapshot.revision)
        switch snapshot.phase {
        case .idle:
            resetStopwatch(publish: false, record: false)
            guard stateMachine.state != .idle else {
                return
            }
            stateMachine <- (.idle, snapshot)
        case .work:
            timerMode = .pomodoro
            UserDefaults.standard.set(timerMode.rawValue, forKey: Self.timerModeKey)
            resetStopwatch(publish: false, record: false)
            if stateMachine.state == .work {
                configureWork(from: snapshot)
            } else {
                stateMachine <- (.work, snapshot)
            }
        case .rest:
            timerMode = .pomodoro
            UserDefaults.standard.set(timerMode.rawValue, forKey: Self.timerModeKey)
            resetStopwatch(publish: false, record: false)
            if stateMachine.state == .rest {
                configureRest(from: snapshot)
            } else {
                stateMachine <- (.rest, snapshot)
            }
        case .stopwatchRunning, .stopwatchPaused:
            if stateMachine.state != .idle {
                stateMachine <- (.idle, snapshot)
            }
            configureStopwatch(from: snapshot)
        }
    }

    private func configureWork(from snapshot: TBActiveTimerSnapshot) {
        let startedAt = snapshot.startedAt ?? Date()
        let expectedEndAt = snapshot.expectedEndAt ?? startedAt.addingTimeInterval(TimeInterval(workIntervalLength * 60))
        configureWork(
            sessionID: snapshot.sessionID ?? UUID(),
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: max(snapshot.focusIndexInSet, 1),
            workIntervalsInSet: max(snapshot.workIntervalsInSet, 1)
        )
    }

    private func configureWork(sessionID: UUID,
                               startedAt: Date,
                               expectedEndAt: Date,
                               focusIndexInSet: Int,
                               workIntervalsInSet: Int) {
        activeRestKind = nil
        consecutiveWorkIntervals = max(0, min(focusIndexInSet - 1, workIntervalsInSet - 1))
        activeFocusSession = TBActiveFocusSession(
            id: sessionID,
            startedAt: startedAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            plannedDurationSeconds: max(1, Int(expectedEndAt.timeIntervalSince(startedAt)))
        )
        TBStatusItem.shared.setIcon(name: .work)
        startTimer(until: expectedEndAt)
        player.startTicking()
    }

    private func configureRest(from snapshot: TBActiveTimerSnapshot) {
        let startedAt = snapshot.startedAt ?? Date()
        let expectedEndAt = snapshot.expectedEndAt ?? startedAt.addingTimeInterval(TimeInterval(shortRestIntervalLength * 60))
        activeRestKind = snapshot.restKind ?? .short
        consecutiveWorkIntervals = min(max(snapshot.focusIndexInSet, 0), max(snapshot.workIntervalsInSet, 1))
        TBStatusItem.shared.setIcon(name: activeRestKind == .long ? .longRest : .shortRest)
        startTimer(until: expectedEndAt)
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
        TBStatusItem.shared.setIcon(name: stopwatchPhase == .running ? .work : .idle)
        startStopwatchTicking()
        updateStopwatchStrings()
    }

    private func snapshot(from context: TBStateMachine.Context) -> TBActiveTimerSnapshot? {
        context.userInfo as? TBActiveTimerSnapshot
    }
}
