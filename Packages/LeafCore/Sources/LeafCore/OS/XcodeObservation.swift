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
///
/// Phase Track-6 P2 (2026-05-16) — extended with `runDestinationName` +
/// `runDestinationBucket`. The raw name is the AppleScript output (e.g.
/// "Alex's iPhone"); it must NEVER reach `RawEvent.payload`. The bucket is
/// the parser-derived enum value, suitable for export. See spec §4.6.
///
/// Phase Track-9 T1 (2026-05-19) — extended with `line` (current editor line
/// number). Descriptive metadata only; line change alone does NOT trigger a
/// doc_changed event. See spec §T1.
public struct XcodeObservation: AdapterObservation, Hashable {
    public let activeDocPath: String?
    public let projectName: String?
    public let schemeName: String?
    public let buildState: XcodeBuildState
    /// Raw run destination name from AppleScript. Stored here so the parser
    /// can apply bucketing in one place; downstream consumers (state machine
    /// + sink) MUST NOT copy this value into events.
    public let runDestinationName: String?
    public let runDestinationBucket: RunDestinationBucket
    /// Current editor line number. Emitted as payload["line"] = String(Int)
    /// when non-nil. Does NOT trigger doc_changed transitions on its own.
    public let line: Int?

    public init(
        activeDocPath: String?,
        projectName: String?,
        schemeName: String?,
        buildState: XcodeBuildState,
        runDestinationName: String? = nil,
        runDestinationBucket: RunDestinationBucket = .unknown,
        line: Int? = nil
    ) {
        self.activeDocPath = activeDocPath
        self.projectName = projectName
        self.schemeName = schemeName
        self.buildState = buildState
        self.runDestinationName = runDestinationName
        self.runDestinationBucket = runDestinationBucket
        self.line = line
    }
}
