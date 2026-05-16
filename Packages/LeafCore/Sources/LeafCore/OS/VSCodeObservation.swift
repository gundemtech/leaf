import Foundation

/// Track-6 P6 — vscode-family (VSCode / Cursor / Insiders / VSCodium) boundary
/// value type. Carries IDE bundle ID + workspace basename + file basename only.
/// Never raw path, file content, console output, debugger state.
/// Deliberately not an `AdapterObservation`: vscode-family has no AppleScript dictionary,
/// so dispatch lives in `AttentionEmissionPlanner` (planner-level), not the AS adapter registry (spec §3.1).
public struct VSCodeObservation: Hashable, Sendable {
    public let ideBundleID: String
    public let workspaceName: String?
    public let fileBasename: String?

    public init(ideBundleID: String, workspaceName: String?, fileBasename: String?) {
        self.ideBundleID = ideBundleID
        self.workspaceName = workspaceName
        self.fileBasename = fileBasename
    }
}
