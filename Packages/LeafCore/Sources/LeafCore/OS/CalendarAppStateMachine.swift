import Foundation

/// Phase Track-4 S2 — pure transition detector for Calendar.app view state.
/// Emits `calendar_app_view_changed` when view mode OR visible date span
/// changes. Boundary carries no event titles / attendees — those live behind
/// EventKit and were never available to AS in the first place.
public struct CalendarAppStateMachine: Sendable, Hashable {
    private var prev: CalendarAppViewObservation?

    public init() {}

    public mutating func observe(_ obs: CalendarAppViewObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        let changed: Bool = {
            guard let p = prev else { return true }
            return p.viewMode != obs.viewMode
                || p.visibleDateRangeDays != obs.visibleDateRangeDays
        }()
        guard changed else { return [] }
        let payload: [String: String] = [
            "event_kind": "calendar_app_view_changed",
            "view_mode": obs.viewMode.rawValue,
            "visible_date_range_days": String(obs.visibleDateRangeDays),
        ]
        return [
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
                signalType: .attention,
                bundleID: "com.apple.iCal",
                payload: payload
            )
        ]
    }
}
