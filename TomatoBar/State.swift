import SwiftState

typealias TBStateMachine = StateMachine<TBStateMachineStates, TBStateMachineEvents>

enum TBStateMachineEvents: EventType {
    case startStop, stop, timerFired, skipRest
}

enum TBStateMachineStates: StateType {
    case idle, work, rest, pausedWork, pausedRest
}
