import Foundation

/// Phase Track-4 S1 — pure transition detector for the Focus mode boolean
/// produced by `FocusModeCollector`. Same shape as `MeetingStateMachine`.
public struct FocusStateMachine: Sendable, Hashable {
    public enum Transition: Sendable, Hashable {
        case enabled
        case disabled
    }

    private var lastIsFocused: Bool?

    public init() {}

    public mutating func observe(
        _ observation: FocusObservation,
        nowMs: Int64
    ) -> Transition? {
        defer { lastIsFocused = observation.isFocused }
        guard let prior = lastIsFocused else { return nil }
        if prior == observation.isFocused { return nil }
        return observation.isFocused ? .enabled : .disabled
    }
}
