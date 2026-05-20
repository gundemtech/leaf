import Foundation

public struct TodayMetrics: Equatable, Hashable, Sendable {
    public let focusedMin: Int
    public let aiRatio: Double
    public let sessionsCount: Int
    public let switchCount: Int
    public let commitsCount: Int
    public let surfacePills: [SurfacePill]

    public static let empty = TodayMetrics(
        focusedMin: 0, aiRatio: 0, sessionsCount: 0,
        switchCount: 0, commitsCount: 0, surfacePills: [])

    public init(
        focusedMin: Int, aiRatio: Double, sessionsCount: Int, switchCount: Int,
        commitsCount: Int, surfacePills: [SurfacePill]
    ) {
        self.focusedMin = focusedMin
        self.aiRatio = aiRatio
        self.sessionsCount = sessionsCount
        self.switchCount = switchCount
        self.commitsCount = commitsCount
        self.surfacePills = surfacePills
    }
}

/// Track-9 T6 — discriminator. `.captureTime` carries duration in seconds
/// (UI renders "Xh Ym" / "Nm" / "<1m"); `.actionNoun` carries discrete event
/// count (UI renders "N"). Drives `TodayBlock` pillStrip label formatting.
public enum SurfacePillKind: String, Equatable, Hashable, Sendable, Codable {
    case captureTime
    case actionNoun
}

public struct SurfacePill: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let count: Int
    public let kind: SurfacePillKind

    public init(id: String, label: String, count: Int, kind: SurfacePillKind) {
        self.id = id
        self.label = label
        self.count = count
        self.kind = kind
    }
}
