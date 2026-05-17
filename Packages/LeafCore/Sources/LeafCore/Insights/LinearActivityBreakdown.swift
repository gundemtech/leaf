import Foundation

/// Phase 4.2 — Linear issue activity для DerivedInsights.linearActivity(period:).
/// Метаданные only (issue_key, title, status, project) — bodies/comments not stored.
public struct LinearActivityBreakdown: Sendable, Hashable {
    /// Distinct issue keys touched в окне periodа.
    public let issuesTouched: Int
    /// Top-N project bucket'ов по count, descending. Пустая проекция → пустой массив.
    public let byProject: [ProjectCountEntry]
    /// Top-N status bucket'ов по count, descending.
    public let byStatus: [StatusCountEntry]
    /// Phase 4.6.A.2 — distribution of `completedAt - startedAt` (seconds) over
    /// issues completed в окне. `nil` → нет samples (никто не завершён,
    /// либо timestamps отсутствовали).
    public let completionDurationStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved под per-provider WoW в 4.7+. Сейчас всегда nil
    /// (global `weekOverWeekDelta` surface'ится отдельно).
    public let wowDeltaPct: Double?
    /// Phase 4.6.C.3 — consecutive days с ≥1 closed Linear issue
    /// (event_kind='issue_updated' AND completion_seconds IS NOT NULL),
    /// ending today (или yesterday если сегодня ещё нет close-event'а).
    /// 60-day lookback window — semantically GLOBAL метрика, period parameter
    /// в `linearActivity()` НЕ ограничивает streak. `nil` ↔ streak=0.
    public let issueCloseStreak: Int?
    /// Phase 4.6.B — counts моих status transitions за `period`. `nil` ↔
    /// total=0 (не было transitions / Linear не подключён). UI рендерит
    /// строку только при `total > 0`.
    public let transitions: LinearTransitionBreakdown?
    /// Phase 4.6.B — soft "follow-through" ratio = `completed / (completed +
    /// started + reopened)`. `nil` ↔ `completed == 0` (избегает misleading
    /// "0% follow-through" UX для типичного in-progress дня без закрытий).
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

    public static let empty = Self(
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
