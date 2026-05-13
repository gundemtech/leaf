import Foundation

public enum XcodeBuildState: String, Sendable, Codable, Hashable {
    case idle
    case running
    case succeeded
    case failed
}

/// Phase Track-4 S2 — Xcode boundary value type. Only the active document
/// path / project name / scheme name / build state cross the OS boundary. No
/// `text of document`, `contents`, file body, breakpoint state, etc.
public struct XcodeObservation: AdapterObservation, Hashable {
    public let activeDocPath: String?
    public let projectName: String?
    public let schemeName: String?
    public let buildState: XcodeBuildState

    public init(
        activeDocPath: String?,
        projectName: String?,
        schemeName: String?,
        buildState: XcodeBuildState
    ) {
        self.activeDocPath = activeDocPath
        self.projectName = projectName
        self.schemeName = schemeName
        self.buildState = buildState
    }
}
