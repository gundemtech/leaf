import Foundation

/// Phase 2.3 — detailed AI-collaboration breakdown for a period. The UI consumes
/// `ratio` (via `InsightsSnapshot.aiRatio`); MCP `get_ai_activity` returns
/// the full breakdown as versioned JSON. `aiRatio()` in `DerivedInsights`
/// delegates to `aiActivityBreakdown(period:).ratio` (single source of truth).
///
/// `ratio` — per-minute bucket union: minutes_with_ai / minutes_with_ai_or_attention.
/// Always `0...1`; `0` means either "AI off" or "no activity at all".
public struct AIActivityBreakdown: Sendable, Hashable {
    /// `0..1`. Fraction of minutes with ≥1 aiCollaboration event out of the union with attention.
    public let ratio: Double
    /// Sum of distinct AI-active minutes × 60.
    public let aiActiveSeconds: TimeInterval
    /// Union AI ∪ attention minutes × 60. `0` if the window has no active minute at all.
    public let totalActiveSeconds: TimeInterval
    /// Distinct `session_id` (Claude Code session UUID) in the window.
    public let sessionCount: Int
    /// Top-N tools by count. Sorted desc; tiebreak — alphabetical.
    public let topTools: [ToolCountEntry]
    /// Top-N projects by AI-active seconds. Key — `cwd` from the payload.
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

    public static let empty = AIActivityBreakdown(
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
