import Foundation

/// Phase Track-4 S2 — pure transition detector for Arc tab sets. Mirrors
/// `SafariStateMachine` shape.
public struct ArcStateMachine: Sendable, Hashable {
    private var prevURLSet: Set<String>?
    private static let bundleID: String = "company.thebrowser.Browser"
    private static let eventKind: String = "arc_tabs_changed"

    public init() {}

    public mutating func observe(_ obs: ArcObservation, nowMs: Int64) -> [RawEvent] {
        let nextURLSet = Set(obs.tabs.map { $0.url })
        defer { prevURLSet = nextURLSet }
        let changed: Bool = {
            guard let p = prevURLSet else { return true }
            return p != nextURLSet
        }()
        guard changed else { return [] }
        return [Self.makeEvent(obs, nowMs: nowMs)]
    }

    private static func makeEvent(_ obs: ArcObservation, nowMs: Int64) -> RawEvent {
        var payload: [String: String] = ["event_kind": Self.eventKind]
        if let id = obs.activeWindowID { payload["active_window_id"] = id }
        if let data = try? JSONEncoder().encode(obs.tabs), let json = String(data: data, encoding: .utf8) {
            payload["tabs"] = json
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: Self.bundleID,
            payload: payload
        )
    }
}
