import Foundation

public struct XcodeActivityBreakdown: Equatable, Sendable {
    public let buildCount: Int
    public let testRunCount: Int
    public let buildSuccessCount: Int
    public let buildFailureCount: Int
    public let testPassCount: Int
    public let testFailCount: Int
    /// Top 5, descending by event count.
    public let topSchemes: [String]
    /// Top 5 bucketed `RunDestinationBucket` raw values, descending by count.
    public let topDestinations: [String]
    /// 7 values (oldest → newest).
    public let dailyBuilds: [Double]

    public init(
        buildCount: Int,
        testRunCount: Int,
        buildSuccessCount: Int,
        buildFailureCount: Int,
        testPassCount: Int,
        testFailCount: Int,
        topSchemes: [String],
        topDestinations: [String],
        dailyBuilds: [Double]
    ) {
        self.buildCount = buildCount
        self.testRunCount = testRunCount
        self.buildSuccessCount = buildSuccessCount
        self.buildFailureCount = buildFailureCount
        self.testPassCount = testPassCount
        self.testFailCount = testFailCount
        self.topSchemes = topSchemes
        self.topDestinations = topDestinations
        self.dailyBuilds = dailyBuilds
    }

    public static let empty = XcodeActivityBreakdown(
        buildCount: 0,
        testRunCount: 0,
        buildSuccessCount: 0,
        buildFailureCount: 0,
        testPassCount: 0,
        testFailCount: 0,
        topSchemes: [],
        topDestinations: [],
        dailyBuilds: []
    )
}
