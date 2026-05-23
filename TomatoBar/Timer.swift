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
    let startedFromRemote: Bool
}

class TBTimer: ObservableObject {
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
    @Published private var consecutiveWorkIntervals: Int = 0
    @Published private var activeRestKind: TBRestKind?
    private var activeFocusSession: TBActiveFocusSession?
    private var activeTimerRevision: Int = 0
    private var isFollowingRemoteTimer = false
    private var cancellables: Set<AnyCancellable> = []
    private var notificationCenter = TBNotificationCenter()
    private var finishTime: Date?
    private var timerFormatter = DateComponentsFormatter()
    @Published var timeLeftString: String = ""
    @Published var timer: DispatchSourceTimer?

    var statusTitle: String {
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

    private var currentFocusIndexInSet: Int {
        min(max(consecutiveWorkIntervals + (stateMachine.state == .work ? 1 : 0), 1), safeWorkIntervalsInSet)
    }

    private var safeWorkIntervalsInSet: Int {
        max(workIntervalsInSet, 1)
    }

    init() {
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
        bindActiveTimerSync()
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
        stateMachine <-! .startStop
    }

    func skipRest() {
        stateMachine <-! .skipRest
    }

    func updateTimeLeft() {
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
                if isFollowingRemoteTimer {
                    stopTimer()
                    return
                }
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
            workIntervalsInSet: safeWorkIntervalsInSet,
            startedFromRemote: false
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
        let suppressSound = activeFocusSession?.startedFromRemote == true
        finishActiveFocusSession(completed: true)
        consecutiveWorkIntervals += 1
        if !suppressSound {
            player.playDing()
        }
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
        isFollowingRemoteTimer = false
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
            sessionID: sessionID,
            sourceDeviceID: TBDeviceIdentity.current
        ))
    }

    private func bindActiveTimerSync() {
        activeTimerStore.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.applyRemoteActiveTimerSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    private func resumeActiveTimerIfNeeded() {
        guard let snapshot = activeTimerStore.snapshot,
              snapshot.phase != .idle,
              snapshot.expectedEndAt ?? Date() > Date() else {
            return
        }

        applyActiveTimerSnapshot(snapshot)
    }

    private func applyRemoteActiveTimerSnapshot(_ snapshot: TBActiveTimerSnapshot) {
        guard snapshot.sourceDeviceID != TBDeviceIdentity.current else {
            return
        }
        applyActiveTimerSnapshot(snapshot)
    }

    private func applyActiveTimerSnapshot(_ snapshot: TBActiveTimerSnapshot) {
        activeTimerRevision = max(activeTimerRevision, snapshot.revision)
        switch snapshot.phase {
        case .idle:
            guard stateMachine.state != .idle else {
                return
            }
            stateMachine <- (.idle, snapshot)
        case .work:
            if stateMachine.state == .work {
                configureWork(from: snapshot)
            } else {
                stateMachine <- (.work, snapshot)
            }
        case .rest:
            if stateMachine.state == .rest {
                configureRest(from: snapshot)
            } else {
                stateMachine <- (.rest, snapshot)
            }
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
            workIntervalsInSet: max(snapshot.workIntervalsInSet, 1),
            startedFromRemote: snapshot.sourceDeviceID != TBDeviceIdentity.current
        )
    }

    private func configureWork(sessionID: UUID,
                               startedAt: Date,
                               expectedEndAt: Date,
                               focusIndexInSet: Int,
                               workIntervalsInSet: Int,
                               startedFromRemote: Bool) {
        activeRestKind = nil
        consecutiveWorkIntervals = max(0, min(focusIndexInSet - 1, workIntervalsInSet - 1))
        isFollowingRemoteTimer = startedFromRemote
        activeFocusSession = TBActiveFocusSession(
            id: sessionID,
            startedAt: startedAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: workIntervalsInSet,
            plannedDurationSeconds: max(1, Int(expectedEndAt.timeIntervalSince(startedAt))),
            startedFromRemote: startedFromRemote
        )
        TBStatusItem.shared.setIcon(name: .work)
        startTimer(until: expectedEndAt)
        if !startedFromRemote {
            player.startTicking()
        }
    }

    private func configureRest(from snapshot: TBActiveTimerSnapshot) {
        let startedAt = snapshot.startedAt ?? Date()
        let expectedEndAt = snapshot.expectedEndAt ?? startedAt.addingTimeInterval(TimeInterval(shortRestIntervalLength * 60))
        activeRestKind = snapshot.restKind ?? .short
        isFollowingRemoteTimer = snapshot.sourceDeviceID != TBDeviceIdentity.current
        consecutiveWorkIntervals = min(max(snapshot.focusIndexInSet, 0), max(snapshot.workIntervalsInSet, 1))
        TBStatusItem.shared.setIcon(name: activeRestKind == .long ? .longRest : .shortRest)
        startTimer(until: expectedEndAt)
    }

    private func snapshot(from context: TBStateMachine.Context) -> TBActiveTimerSnapshot? {
        context.userInfo as? TBActiveTimerSnapshot
    }
}
