import Foundation

/// Track-10 T5 — UserDefaults-backed cursor for the SINCE YOU WERE LAST ACTIVE
/// timeline. Single-source-of-truth for "how far back to look for delta events".
///
/// Semantics:
/// - First read (no UserDefaults value) — seeds to `now() - 24h` AND persists immediately.
///   This delivers immediate first-open UX value: SINCE shows yesterday's deltas.
/// - Subsequent reads return persisted value verbatim (no clock-based recompute).
/// - `markAllAsSeen(now:)` advances cursor to `now()` AND persists.
///
/// Reactivity via `@Observable` macro. Consumers inject via
/// `@Environment(LastSeenCursor.self)` from LeafApp root. InsightsReader receives
/// reference at configure() and reads `cursor.lastSeenAtMs` at refresh() ordinal-22.
@Observable
@MainActor
public final class LastSeenCursor {
    public static let userDefaultsKey = "leaf.ui.lastSeenAtMs"
    private static let firstReadLookbackMs: Int64 = 24 * 3600 * 1000

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.clock = clock
    }

    public var lastSeenAtMs: Int64 {
        if let persisted = (defaults.object(forKey: Self.userDefaultsKey) as? NSNumber)?.int64Value
        {
            return persisted
        }
        let seeded = Int64(clock().timeIntervalSince1970 * 1000) - Self.firstReadLookbackMs
        defaults.set(NSNumber(value: seeded), forKey: Self.userDefaultsKey)
        return seeded
    }

    public func markAllAsSeen(now: Date) {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        defaults.set(NSNumber(value: ms), forKey: Self.userDefaultsKey)
    }
}
