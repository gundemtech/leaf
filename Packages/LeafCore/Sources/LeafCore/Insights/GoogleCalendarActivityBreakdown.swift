import Foundation

public struct GoogleCalendarActivityBreakdown: Sendable, Hashable {
    public let focusBlockCount: Int
    public let focusDurationSeconds: TimeInterval
    public let oooBlockCount: Int
    public let workingLocationCount: Int
    /// 7 values (oldest → newest).
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

    public static let empty = GoogleCalendarActivityBreakdown(
        focusBlockCount: 0,
        focusDurationSeconds: 0,
        oooBlockCount: 0,
        workingLocationCount: 0,
        dailyFocusMinutes: []
    )
}
