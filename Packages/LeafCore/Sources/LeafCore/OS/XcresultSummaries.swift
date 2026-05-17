import Foundation

/// Phase Track-6 P2 — structured fields extracted from
/// `xcrun xcresulttool get build-results summary --legacy --path <bundle>`.
/// See spec §4.3. Walkback is applied at parser layer; this type does not
/// carry forbidden fields (errors[].message, sourceURL, destination.deviceName,
/// etc.) by construction.
public struct XcresultBuildSummary: Sendable, Equatable, Hashable {
    public let errorCount: Int
    public let warningCount: Int
    public let analyzerWarningCount: Int
    public let targetNames: Set<String>  // ONLY from errors[].targetName, allowlisted
    public let destinationBucket: RunDestinationBucket
    public let durationMs: Int64?
    public let scheme: String?

    public init(
        errorCount: Int,
        warningCount: Int,
        analyzerWarningCount: Int,
        targetNames: Set<String>,
        destinationBucket: RunDestinationBucket,
        durationMs: Int64?,
        scheme: String?
    ) {
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.analyzerWarningCount = analyzerWarningCount
        self.targetNames = targetNames
        self.destinationBucket = destinationBucket
        self.durationMs = durationMs
        self.scheme = scheme
    }
}

/// Phase Track-6 P2 — structured fields from
/// `xcrun xcresulttool get test-results summary --legacy --path <bundle>`.
/// See spec §4.3. Individual test names + failure messages are NEVER read by
/// the parser; this struct only carries aggregate counts.
public struct XcresultTestSummary: Sendable, Equatable, Hashable {
    public let passedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let expectedFailureCount: Int
    public let totalCount: Int
    public let durationMs: Int64?
    public let scheme: String?
    public let destinationBucket: RunDestinationBucket

    public init(
        passedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        expectedFailureCount: Int,
        totalCount: Int,
        durationMs: Int64?,
        scheme: String?,
        destinationBucket: RunDestinationBucket
    ) {
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.expectedFailureCount = expectedFailureCount
        self.totalCount = totalCount
        self.durationMs = durationMs
        self.scheme = scheme
        self.destinationBucket = destinationBucket
    }
}
