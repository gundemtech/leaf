import Foundation

public struct InboxItem: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: InboxKind
    public let severity: InboxSeverity
    public let title: String
    public let sourceMeta: String
    public let sourceURL: URL?
    public let aggregatedCount: Int
    public let createdAtMs: Int64

    public init(
        id: String, kind: InboxKind, severity: InboxSeverity, title: String,
        sourceMeta: String, sourceURL: URL?, aggregatedCount: Int, createdAtMs: Int64
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.sourceMeta = sourceMeta
        self.sourceURL = sourceURL
        self.aggregatedCount = aggregatedCount
        self.createdAtMs = createdAtMs
    }
}

public enum InboxKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case reviewRequest
    case commentOnMyWork
    case mention
    case openQuestion
    case blocker
}

public enum InboxSeverity: String, Equatable, Hashable, Sendable {
    case danger
    case warn
    case muted

    public var sortRank: Int {
        switch self {
        case .danger: return 0
        case .warn: return 1
        case .muted: return 2
        }
    }
}

public enum InboxFilter: String, Equatable, Hashable, Sendable, CaseIterable {
    case all
    case reviews
    case questions
    case mentions

    /// Returns true if the filter admits this kind.
    public func admits(_ kind: InboxKind) -> Bool {
        switch self {
        case .all: return true
        case .reviews: return kind == .reviewRequest
        case .questions: return kind == .openQuestion
        case .mentions: return kind == .mention
        }
    }
}
