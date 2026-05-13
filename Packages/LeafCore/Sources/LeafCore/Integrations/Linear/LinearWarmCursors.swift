import Foundation

/// Phase Track-3 D1 — cursor pair for warm-tier Linear poll. Each field is
/// epoch ms newest processed timestamp; nil → bootstrap (provider applies
/// 7-day backfill window per `LinearCollector.backfillWindowDays`).
public struct LinearWarmCursors: Sendable, Hashable {
    public let notificationsSince: Int64?
    public let cyclesSince: Int64?

    public init(notificationsSince: Int64?, cyclesSince: Int64?) {
        self.notificationsSince = notificationsSince
        self.cyclesSince = cyclesSince
    }
}
