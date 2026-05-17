import Foundation

/// Phase 2.3 — детальный AI-collaboration срез за период. UI потребляет
/// `ratio` (через `InsightsSnapshot.aiRatio`); MCP `get_ai_activity` отдаёт
/// весь breakdown как versioned JSON. `aiRatio()` в `DerivedInsights` —
/// делегирует в `aiActivityBreakdown(period:).ratio` (single source of truth).
///
/// `ratio` — per-minute bucket union: minutes_with_ai / minutes_with_ai_or_attention.
/// Всегда `0...1`; `0` означает либо "AI off", либо "никакой активности вообще".
public struct AIActivityBreakdown: Sendable, Hashable {
    /// `0..1`. Доля минут с ≥1 aiCollaboration event от union с attention.
    public let ratio: Double
    /// Сумма distinct AI-active minutes × 60.
    public let aiActiveSeconds: TimeInterval
    /// Union AI ∪ attention minutes × 60. `0` если в окне нет ни одной активной минуты.
    public let totalActiveSeconds: TimeInterval
    /// Distinct `session_id` (Claude Code session UUID) в окне.
    public let sessionCount: Int
    /// Top-N tools по count. Sorted desc; tiebreak — alphabetical.
    public let topTools: [ToolCountEntry]
    /// Top-N projects по AI-active seconds. Key — `cwd` из payload.
    public let topProjects: [ProjectTimeEntry]

    public init(
        ratio: Double,
        aiActiveSeconds: TimeInterval,
        totalActiveSeconds: TimeInterval,
        sessionCount: Int,
        topTools: [ToolCountEntry],
        topProjects: [ProjectTimeEntry]
    ) {
        self.ratio = ratio
        self.aiActiveSeconds = aiActiveSeconds
        self.totalActiveSeconds = totalActiveSeconds
        self.sessionCount = sessionCount
        self.topTools = topTools
        self.topProjects = topProjects
    }

    public static let empty = Self(
        ratio: 0,
        aiActiveSeconds: 0,
        totalActiveSeconds: 0,
        sessionCount: 0,
        topTools: [],
        topProjects: []
    )
}

public struct ToolCountEntry: Sendable, Hashable, Codable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct ProjectTimeEntry: Sendable, Hashable, Codable {
    public let cwd: String
    public let aiActiveSeconds: TimeInterval

    public init(cwd: String, aiActiveSeconds: TimeInterval) {
        self.cwd = cwd
        self.aiActiveSeconds = aiActiveSeconds
    }
}
