import Foundation

/// Phase Track-4 S2 — pure transition detector for Reminders. Emits
/// `reminder_completed` only when the per-tick completion delta is positive
/// (≥1 newly-completed items in the active list since the previous tick).
/// First observation seeds state and emits nothing.
public struct RemindersStateMachine: Sendable, Hashable {
    private var initialised: Bool = false

    public init() {}

    public mutating func observe(_ obs: RemindersCompletionObservation, nowMs: Int64) -> [RawEvent] {
        defer { initialised = true }
        guard initialised else { return [] }
        guard obs.completedCountDelta > 0 else { return [] }
        var payload: [String: String] = [
            "event_kind": "reminder_completed",
            "completed_count_delta": String(obs.completedCountDelta),
        ]
        if let name = obs.listName { payload["list_name"] = name }
        return [
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
                signalType: .action,
                bundleID: "com.apple.reminders",
                payload: payload
            )
        ]
    }
}
