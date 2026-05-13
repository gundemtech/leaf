import Foundation

/// Phase Track-4 S2 — pure transition detector for Xcode observations.
/// Emits up to two `RawEvent`s per tick:
///   - `xcode_active_doc_changed` if (path / project / scheme) differs
///   - `xcode_build_state_changed` if the build status enum flipped
/// First observation emits both events; subsequent identical observations
/// emit nothing.
public struct XcodeStateMachine: Sendable, Hashable {
    private var prev: XcodeObservation?

    public init() {}

    public mutating func observe(_ obs: XcodeObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        var events: [RawEvent] = []
        let docChanged: Bool = {
            guard let p = prev else { return true }
            return p.activeDocPath != obs.activeDocPath
                || p.projectName != obs.projectName
                || p.schemeName != obs.schemeName
        }()
        if docChanged {
            events.append(Self.makeDocChangedEvent(obs, nowMs: nowMs))
        }
        let buildChanged: Bool = {
            guard let p = prev else { return true }
            return p.buildState != obs.buildState
        }()
        if buildChanged {
            events.append(Self.makeBuildStateChangedEvent(obs, nowMs: nowMs))
        }
        return events
    }

    private static func makeDocChangedEvent(_ obs: XcodeObservation, nowMs: Int64) -> RawEvent {
        var payload: [String: String] = ["event_kind": "xcode_active_doc_changed"]
        if let p = obs.activeDocPath { payload["doc_path"] = p }
        if let pj = obs.projectName { payload["project"] = pj }
        if let s = obs.schemeName { payload["scheme"] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: payload
        )
    }

    private static func makeBuildStateChangedEvent(_ obs: XcodeObservation, nowMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "event_kind": "xcode_build_state_changed",
            "build_state": obs.buildState.rawValue
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: payload
        )
    }
}
