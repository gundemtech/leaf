import Foundation

/// Phase 4.2 — Linear issue activity for DerivedInsights.linearActivity(period:).
/// Metadata only (issue_key, title, status, project) — bodies/comments not stored.
public struct LinearActivityBreakdown: Sendable, Hashable {
    /// Distinct issue keys touched within the period window.
    public let issuesTouched: Int
    /// Top-N project buckets by count, descending. Empty projection → empty array.
    public let byProject: [ProjectCountEntry]
    /// Top-N status buckets by count, descending.
    public let byStatus: [StatusCountEntry]
    /// Phase 4.6.A.2 — distribution of `completedAt - startedAt` (seconds) over
    /// issues completed in the window. `nil` → no samples (nothing completed,
    /// or timestamps were missing).
    public let completionDurationStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved for per-provider WoW in 4.7+. Always nil for now
    /// (global `weekOverWeekDelta` is surfaced separately).
    public let wowDeltaPct: Double?
    /// Phase 4.6.C.3 — consecutive days with ≥1 closed Linear issue
    /// (event_kind='issue_updated' AND completion_seconds IS NOT NULL),
    /// ending today (or yesterday if there's no close-event yet today).
    /// 60-day lookback window — semantically a GLOBAL metric; the period parameter
    /// in `linearActivity()` does NOT bound the streak. `nil` ↔ streak=0.
    public let issueCloseStreak: Int?
    /// Phase 4.6.B — counts of my status transitions over `period`. `nil` ↔
    /// total=0 (no transitions / Linear not connected). The UI renders the
    /// line only when `total > 0`.
    public let transitions: LinearTransitionBreakdown?
    /// Phase 4.6.B — soft "follow-through" ratio = `completed / (completed +
    /// started + reopened)`. `nil` ↔ `completed == 0` (avoids a misleading
    /// "0% follow-through" UX for a typical in-progress day with no closes).
    public let completionRate: Double?

    public init(
        issuesTouched: Int,
        byProject: [ProjectCountEntry],
        byStatus: [StatusCountEntry],
        completionDurationStats: LatencyStats? = nil,
        wowDeltaPct: Double? = nil,
        issueCloseStreak: Int? = nil,
        transitions: LinearTransitionBreakdown? = nil,
        completionRate: Double? = nil
    ) {
        self.issuesTouched = issuesTouched
        self.byProject = byProject
        self.byStatus = byStatus
        self.completionDurationStats = completionDurationStats
        self.wowDeltaPct = wowDeltaPct
        self.issueCloseStreak = issueCloseStreak
        self.transitions = transitions
        self.completionRate = completionRate
    }

    public static let empty = LinearActivityBreakdown(
        issuesTouched: 0,
        byProject: [],
        byStatus: [],
        completionDurationStats: nil,
        wowDeltaPct: nil,
        issueCloseStreak: nil,
        transitions: nil,
        completionRate: nil
    )
}

public struct ProjectCountEntry: Sendable, Hashable, Codable {
    public let project: String
    public let count: Int
    public init(project: String, count: Int) {
        self.project = project
        self.count = count
    }
}

public struct StatusCountEntry: Sendable, Hashable, Codable {
    public let status: String
    public let count: Int
    public init(status: String, count: Int) {
        self.status = status
        self.count = count
    }
}
