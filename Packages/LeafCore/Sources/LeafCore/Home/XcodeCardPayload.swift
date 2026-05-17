import Foundation

public struct XcodeCardPayload: Equatable, Sendable {
    public let buildCount: Int
    public let testRunCount: Int
    public let buildSuccessCount: Int
    public let buildFailureCount: Int
    public let schemesTouchedCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet computed".
    public let dailyBuilds: [Double]

    public init(
        buildCount: Int,
        testRunCount: Int,
        buildSuccessCount: Int,
        buildFailureCount: Int,
        schemesTouchedCount: Int,
        dailyBuilds: [Double]
    ) {
        self.buildCount = buildCount
        self.testRunCount = testRunCount
        self.buildSuccessCount = buildSuccessCount
        self.buildFailureCount = buildFailureCount
        self.schemesTouchedCount = schemesTouchedCount
        self.dailyBuilds = dailyBuilds
    }
}
