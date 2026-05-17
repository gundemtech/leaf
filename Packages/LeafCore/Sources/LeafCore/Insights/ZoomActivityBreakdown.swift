import Foundation

public struct ZoomActivityBreakdown: Sendable, Hashable {
    public let meetingCount: Int
    public let totalDurationSeconds: TimeInterval
    public let calendarLinkedCount: Int
    public let adHocCount: Int
    /// Max `duration_ms / 1000` across meetings in the period.
    public let longestMeetingSeconds: TimeInterval
    /// 7 values (oldest → newest).
    public let dailyMinutes: [Double]

    public init(
        meetingCount: Int,
        totalDurationSeconds: TimeInterval,
        calendarLinkedCount: Int,
        adHocCount: Int,
        longestMeetingSeconds: TimeInterval,
        dailyMinutes: [Double]
    ) {
        self.meetingCount = meetingCount
        self.totalDurationSeconds = totalDurationSeconds
        self.calendarLinkedCount = calendarLinkedCount
        self.adHocCount = adHocCount
        self.longestMeetingSeconds = longestMeetingSeconds
        self.dailyMinutes = dailyMinutes
    }

    public static let empty = ZoomActivityBreakdown(
        meetingCount: 0,
        totalDurationSeconds: 0,
        calendarLinkedCount: 0,
        adHocCount: 0,
        longestMeetingSeconds: 0,
        dailyMinutes: []
    )
}
