import KeyboardShortcuts
import SwiftState
import SwiftUI

private struct TBActiveFocusSession {
    let startedAt: Date
    let focusIndexInSet: Int
    let workIntervalsInSet: Int
    let plannedDurationSeconds: Int
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
        publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)

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
        stopTimer()
        let expectedEndAt = startedAt.addingTimeInterval(TimeInterval(seconds))
        finishTime = expectedEndAt

        let queue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer!.setEventHandler(handler: onTimerTick)
        timer!.setCancelHandler(handler: onTimerCancel)
        timer!.resume()
        updateTimeLeft()
        return expectedEndAt
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

    private func onNotificationAction(action: TBNotification.Action) {
        if action == .skipRest, stateMachine.state == .rest {
            skipRest()
        }
    }

    private func onWorkStart(context _: TBStateMachine.Context) {
        let plannedDurationSeconds = workIntervalLength * 60
        let focusIndexInSet = currentFocusIndexInSet
        let startedAt = Date()
        activeRestKind = nil
        activeFocusSession = TBActiveFocusSession(
            startedAt: startedAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: safeWorkIntervalsInSet,
            plannedDurationSeconds: plannedDurationSeconds
        )
        TBStatusItem.shared.setIcon(name: .work)
        player.playWindup()
        player.startTicking()
        let expectedEndAt = startTimer(seconds: plannedDurationSeconds, startedAt: startedAt)
        publishActiveTimer(
            phase: .work,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet
        )
    }

    private func onWorkFinish(context _: TBStateMachine.Context) {
        finishActiveFocusSession(completed: true)
        consecutiveWorkIntervals += 1
        player.playDing()
    }

    private func onWorkEnd(context ctx: TBStateMachine.Context) {
        if ctx.toState == .idle {
            finishActiveFocusSession(completed: false)
        }
        player.stopTicking()
    }

    private func onRestStart(context _: TBStateMachine.Context) {
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
        let expectedEndAt = startTimer(seconds: length * 60, startedAt: startedAt)
        publishActiveTimer(
            phase: .rest,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: min(consecutiveWorkIntervals, safeWorkIntervalsInSet),
            restKind: activeRestKind
        )
    }

    private func onRestFinish(context ctx: TBStateMachine.Context) {
        let finishedLongRest = activeRestKind == .long
        activeRestKind = nil
        if finishedLongRest {
            consecutiveWorkIntervals = 0
        }
        if ctx.event == .skipRest {
            return
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Break is over title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Break is over body"),
            category: .restFinished
        )
    }

    private func onIdleStart(context ctx: TBStateMachine.Context) {
        if ctx.fromState == .work {
            finishActiveFocusSession(completed: false)
        }
        stopTimer()
        TBStatusItem.shared.setIcon(name: .idle)
        activeRestKind = nil
        activeFocusSession = nil
        consecutiveWorkIntervals = 0
        publishActiveTimer(phase: .idle, startedAt: nil, expectedEndAt: nil)
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
                                    restKind: TBRestKind? = nil) {
        activeTimerRevision += 1
        activeTimerStore.save(TBActiveTimerSnapshot(
            phase: phase,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            focusIndexInSet: focusIndexInSet,
            workIntervalsInSet: safeWorkIntervalsInSet,
            restKind: restKind,
            revision: activeTimerRevision,
            updatedAt: Date()
        ))
    }
}
