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

    public init(issuesTouched: Int, byProject: [ProjectCountEntry], byStatus: [StatusCountEntry]) {
        self.issuesTouched = issuesTouched
        self.byProject = byProject
        self.byStatus = byStatus
    }

    public static let empty = LinearActivityBreakdown(issuesTouched: 0, byProject: [], byStatus: [])
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
