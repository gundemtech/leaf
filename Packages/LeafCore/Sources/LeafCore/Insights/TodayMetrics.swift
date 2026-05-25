import Foundation

public struct TodayMetrics: Equatable, Hashable, Sendable {
    public let focusedMin: Int
    public let aiRatio: Double
    public let sessionsCount: Int
    public let switchCount: Int
    public let commitsCount: Int
    public let surfacePills: [SurfacePill]

    public static let empty = TodayMetrics(focusedMin: 0, aiRatio: 0, sessionsCount: 0,
                                           switchCount: 0, commitsCount: 0, surfacePills: [])

    public init(focusedMin: Int, aiRatio: Double, sessionsCount: Int, switchCount: Int,
                commitsCount: Int, surfacePills: [SurfacePill]) {
        self.focusedMin = focusedMin
        self.aiRatio = aiRatio
        self.sessionsCount = sessionsCount
        self.switchCount = switchCount
        self.commitsCount = commitsCount
        self.surfacePills = surfacePills
    }
}

/// Track-9 T6 — discriminator. `.captureTime` carries duration in seconds;
/// `.actionNoun` carries discrete event count. Substrate emission preserved
/// for future re-use (Track-10 T1 dropped TodayBlock UI rendering; no current
/// MCP consumer).
public enum SurfacePillKind: String, Equatable, Hashable, Sendable, Codable {
    case captureTime
    case actionNoun
}

public struct SurfacePill: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let count: Int
    /// Track-10 Phase B — pill family discriminator (capture-time vs
    /// action-noun). Defaulted `.actionNoun` so pre-Phase-B callers stay
    /// source-compatible.
    public let kind: SurfacePillKind

    public init(id: String, label: String, count: Int, kind: SurfacePillKind = .actionNoun) {
        self.id = id
        self.label = label
        self.count = count
        self.kind = kind
    }
}
