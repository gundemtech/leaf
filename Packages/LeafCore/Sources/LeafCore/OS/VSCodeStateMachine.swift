import Foundation

/// Track-6 P6 — vscode-family per-bundle diff detector. Emits
/// `vscode_active_doc_changed` when (workspaceName, fileBasename) tuple
/// differs from prior observation for the given bundleID. Per-bundle Box
/// pattern: vscode + Cursor + Insiders + VSCodium maintain separate prev
/// state. Mirrors `JetBrainsStateMachine` shape (value type, mutating
/// `observe`).
public struct VSCodeStateMachine: Sendable, Hashable {
    private var prev: [String: VSCodeObservation] = [:]

    public init() {}

    public mutating func observe(_ obs: VSCodeObservation, nowMs: Int64) -> [RawEvent] {
        let last = prev[obs.ideBundleID]
        defer { prev[obs.ideBundleID] = obs }
        if let l = last,
           l.workspaceName == obs.workspaceName,
           l.fileBasename == obs.fileBasename {
            return []
        }
        var payload: [String: String] = [
            "event_kind": "vscode_active_doc_changed",
            "ide_bundle_id": obs.ideBundleID
        ]
        if let w = obs.workspaceName { payload["workspace_name"] = w }
        if let f = obs.fileBasename { payload["file_basename"] = f }
        return [RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: obs.ideBundleID,
            payload: payload
        )]
    }
}
