import Foundation

public struct GoogleCalendarCardPayload: Equatable, Sendable {
    public let focusBlockCount: Int
    public let focusDurationSeconds: TimeInterval
    public let oooBlockCount: Int
    public let workingLocationCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet computed".
    public let dailyFocusMinutes: [Double]

    public init(
        focusBlockCount: Int,
        focusDurationSeconds: TimeInterval,
        oooBlockCount: Int,
        workingLocationCount: Int,
        dailyFocusMinutes: [Double]
    ) {
        self.focusBlockCount = focusBlockCount
        self.focusDurationSeconds = focusDurationSeconds
        self.oooBlockCount = oooBlockCount
        self.workingLocationCount = workingLocationCount
        self.dailyFocusMinutes = dailyFocusMinutes
    }
}
