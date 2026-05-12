import Foundation

/// Phase Track-4 S2 — pure transition detector for the JetBrains family.
/// Emits `jetbrains_active_doc_changed` when (ideBundleID, project, doc path)
/// differs from prior observation.
public struct JetBrainsStateMachine: Sendable, Hashable {
    private var prev: JetBrainsObservation?

    public init() {}

    public mutating func observe(_ obs: JetBrainsObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        let changed: Bool = {
            guard let p = prev else { return true }
            return p.ideBundleID != obs.ideBundleID
                || p.projectName != obs.projectName
                || p.activeDocPath != obs.activeDocPath
        }()
        guard changed else { return [] }
        var payload: [String: String] = [
            "event_kind": "jetbrains_active_doc_changed",
            "ide_bundle_id": obs.ideBundleID
        ]
        if let p = obs.projectName { payload["project"] = p }
        if let d = obs.activeDocPath { payload["doc_path"] = d }
        return [RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: obs.ideBundleID,
            payload: payload
        )]
    }
}
