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

public struct SurfacePill: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let count: Int

    public init(id: String, label: String, count: Int) {
        self.id = id
        self.label = label
        self.count = count
    }
}
