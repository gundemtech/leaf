import Foundation

/// Phase Track-4 S1 — pure transition detector for the `in_meeting` boolean
/// produced by `CalendarCollector`. State is `Bool?` initially nil; first
/// observation never emits a transition (bootstrap discipline). Subsequent
/// observations emit only when the boolean flips. Sendable + value semantics
/// — collector copies a fresh instance per polling tick.
public struct MeetingStateMachine: Sendable, Hashable {
    public enum Transition: Sendable, Hashable {
        case entered
        case exited
    }

    private var lastIsInMeeting: Bool?

    public init() {}

    /// Process one observation; return `.entered` / `.exited` if state flipped,
    /// nil if first observation or identical to prior.
    public mutating func observe(
        _ observation: MeetingObservation,
        nowMs: Int64
    ) -> Transition? {
        defer { lastIsInMeeting = observation.isInMeeting }
        guard let prior = lastIsInMeeting else { return nil }
        if prior == observation.isInMeeting { return nil }
        return observation.isInMeeting ? .entered : .exited
    }
}
