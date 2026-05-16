import Foundation

/// Phase Track-3 D1 — cursor pair for warm-tier Linear poll. Each field is
/// epoch ms newest processed timestamp; nil → bootstrap. On bootstrap:
///  - `notificationsSince` → provider applies 7-day backfill window.
///  - `cyclesSince` → provider applies 30-day backfill window (sprints are
///    typically 1-2 weeks; 7-day window misses sprints that started 8+ days ago).
public struct LinearWarmCursors: Sendable, Hashable {
    public let notificationsSince: Int64?
    public let cyclesSince: Int64?

    public init(notificationsSince: Int64?, cyclesSince: Int64?) {
        self.notificationsSince = notificationsSince
        self.cyclesSince = cyclesSince
    }
}
