import Foundation

public struct ZoomCardPayload: Equatable, Sendable {
    /// Count of `zoom_meeting_started` events in the period.
    public let meetingCount: Int
    /// Sum of `duration_ms / 1000` over completed meetings.
    public let totalDurationSeconds: TimeInterval
    public let calendarLinkedCount: Int
    /// `meetingCount - calendarLinkedCount`.
    public let adHocCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet computed".
    public let dailyMinutes: [Double]

    public init(
        meetingCount: Int,
        totalDurationSeconds: TimeInterval,
        calendarLinkedCount: Int,
        adHocCount: Int,
        dailyMinutes: [Double]
    ) {
        self.meetingCount = meetingCount
        self.totalDurationSeconds = totalDurationSeconds
        self.calendarLinkedCount = calendarLinkedCount
        self.adHocCount = adHocCount
        self.dailyMinutes = dailyMinutes
    }
}
