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
    // Existing 5 (preserved order)
    case reviewRequest
    case commentOnMyWork
    case mention
    case openQuestion
    case blocker

    // T8 viable new (3)
    case buildFailed
    case ciFailed
    case liveMeeting

    // T8 placeholder — feeders return [] until substrate phases land
    // See docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md §3.4 lines 100-108
    case calInviteDeclined
    case calUpcoming15min
    case calConflict
    case mailUnreadBucket
    case reminderDueToday
    case slackDM
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
    case actionable  // T4 — "needs YOUR response NOW" umbrella over 7 of 14 InboxKinds
    case reviews
    case questions
    case mentions
    case alerts     // T8 — umbrella for buildFailed + ciFailed + liveMeeting

    /// Returns true if the filter admits this kind.
    public func admits(_ kind: InboxKind) -> Bool {
        switch self {
        case .all:
            return true
        case .actionable:
            // Exhaustive switch on InboxKind is the compile-time fence:
            // adding a 15th kind forces explicit triage on this arm, no
            // silent "default: false" that would surprise a user.
            switch kind {
            case .reviewRequest, .mention, .openQuestion, .blocker,
                 .buildFailed, .ciFailed, .liveMeeting:
                return true
            case .commentOnMyWork, .calInviteDeclined, .calUpcoming15min,
                 .calConflict, .mailUnreadBucket, .reminderDueToday, .slackDM:
                return false
            }
        case .reviews: return kind == .reviewRequest
        case .questions: return kind == .openQuestion
        case .mentions: return kind == .mention
        case .alerts:
            return kind == .buildFailed || kind == .ciFailed || kind == .liveMeeting
        }
    }
}
