import Foundation

/// Phase Track-6 P2 — invocation interface for `xcrun xcresulttool`.
/// Production impl in LeafCorePrivate (`ProdXcresultParser`). Spec §4.3.
public protocol XcresultParser: Sendable {
    func parseBuildSummary(path: String) async throws -> XcresultBuildSummary
    func parseTestSummary(path: String) async throws -> XcresultTestSummary
}

/// Failure modes for `XcresultParser`. The Process stderr is never embedded
/// in the error payload — only the exit code is, to keep ADR-010 walkback
/// discipline at the surface API.
public enum XcresultParseError: Error, Equatable, Sendable {
    case toolMissing
    case timeout
    case nonZeroExit(Int32)
    case malformedJSON
    case legacyFlagRejected
}
