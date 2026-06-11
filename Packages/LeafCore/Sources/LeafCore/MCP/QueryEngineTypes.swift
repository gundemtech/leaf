import Foundation

/// Phase Track-1 D3 — Codable response types for the 3 high-level structured
/// MCP tools (`leaf_query_activity` / `leaf_get_decision` / `leaf_current_work`).
///
/// All responses carry a top-level `schemaVersion` so AI clients can branch on
/// it as the substrate evolves; the current value is `QueryEngineSchema.currentVersion`.
public enum QueryEngineSchema {
    public static let currentVersion = "1.0"
}

/// Inclusive ms range. Used by `queryActivity` + optional `getDecision` scoping.
public struct PeriodSpec: Codable, Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// `leaf_query_activity` response. Composes events + detector tables + cross-source
/// links + optional absence flags. Subject to `events[]` byte-budget trim
/// (`TruncationNote.reason == "byte_budget"`).
public struct QueryActivityResponse: Codable, Sendable {
    public let schemaVersion: String
    public let period: PeriodSpec
    public let filter: String?
    public let events: [ActivityEvent]
    public let decisionsInPeriod: [DecisionView]
    public let openQuestions: [OpenQuestionView]
    public let blockers: [BlockerView]
    public let links: [LinkView]
    public let absenceFlags: [AbsenceFlag]
    public let truncationNote: TruncationNote?

    public init(
        schemaVersion: String = QueryEngineSchema.currentVersion,
        period: PeriodSpec,
        filter: String?,
        events: [ActivityEvent],
        decisionsInPeriod: [DecisionView],
        openQuestions: [OpenQuestionView],
        blockers: [BlockerView],
        links: [LinkView],
        absenceFlags: [AbsenceFlag],
        truncationNote: TruncationNote?
    ) {
        self.schemaVersion = schemaVersion
        self.period = period
        self.filter = filter
        self.events = events
        self.decisionsInPeriod = decisionsInPeriod
        self.openQuestions = openQuestions
        self.blockers = blockers
        self.links = links
        self.absenceFlags = absenceFlags
        self.truncationNote = truncationNote
    }
}

/// `leaf_get_decision` response. `decision == nil` when no FTS match.
public struct GetDecisionResponse: Codable, Sendable {
    public let schemaVersion: String
    public let decision: DecisionDetail?
    public let relatedEvents: [ActivityEvent]
    public let truncationNote: TruncationNote?

    public init(
        schemaVersion: String = QueryEngineSchema.currentVersion,
        decision: DecisionDetail?,
        relatedEvents: [ActivityEvent],
        truncationNote: TruncationNote?
    ) {
        self.schemaVersion = schemaVersion
        self.decision = decision
        self.relatedEvents = relatedEvents
        self.truncationNote = truncationNote
    }
}

/// `leaf_current_work` response — projection of the latest signal-typed events
/// plus open detector state. `whereStopped` is non-nil only when the most recent
/// `where_stopped_log` row was generated within the last 24h.
public struct CurrentWorkResponse: Codable, Sendable {
    public let schemaVersion: String
    public let currentApp: String?
    public let currentBranch: String?
    public let currentFile: String?
    public let inProgressLinearTicket: LinearTicketRef?
    public let lastCommit: CommitRef?
    public let currentOpenQuestions: [OpenQuestionView]
    public let currentBlockers: [BlockerView]
    public let whereStopped: WhereStoppedOutput?

    public init(
        schemaVersion: String = QueryEngineSchema.currentVersion,
        currentApp: String?,
        currentBranch: String?,
        currentFile: String?,
        inProgressLinearTicket: LinearTicketRef?,
        lastCommit: CommitRef?,
        currentOpenQuestions: [OpenQuestionView],
        currentBlockers: [BlockerView],
        whereStopped: WhereStoppedOutput?
    ) {
        self.schemaVersion = schemaVersion
        self.currentApp = currentApp
        self.currentBranch = currentBranch
        self.currentFile = currentFile
        self.inProgressLinearTicket = inProgressLinearTicket
        self.lastCommit = lastCommit
        self.currentOpenQuestions = currentOpenQuestions
        self.currentBlockers = currentBlockers
        self.whereStopped = whereStopped
    }
}

/// One projected `events` row — slim shape (excerpts capped, no full payload).
/// `bodyExcerpt` derived from `payload.body` via `BodyExcerpt.capped`; absent
/// when the source event has no body-bearing payload key.
public struct ActivityEvent: Codable, Sendable, Equatable {
    public let eventID: Int64
    public let tsMs: Int64
    public let signalType: String
    public let bundleID: String?
    public let eventKind: String?
    public let bodyExcerpt: String?
    public let bodyTruncated: Bool
    /// Additive (2026-06-11) — human handle of the event's target when the
    /// allowlisted payload carries one: Linear issue key ("GUN-12") or
    /// GitHub "repo#number". `nil` for events without a structured target.
    public let targetRef: String?
    /// Additive (2026-06-11) — issue / PR title from the allowlisted payload
    /// `title` key. Lets consumers render "GUN-12 · Fix relay reconnect"
    /// instead of dumping the body as a headline.
    public let targetTitle: String?

    public init(
        eventID: Int64,
        tsMs: Int64,
        signalType: String,
        bundleID: String?,
        eventKind: String?,
        bodyExcerpt: String?,
        bodyTruncated: Bool,
        targetRef: String? = nil,
        targetTitle: String? = nil
    ) {
        self.eventID = eventID
        self.tsMs = tsMs
        self.signalType = signalType
        self.bundleID = bundleID
        self.eventKind = eventKind
        self.bodyExcerpt = bodyExcerpt
        self.bodyTruncated = bodyTruncated
        self.targetRef = targetRef
        self.targetTitle = targetTitle
    }
}

/// Slim projection of one `decisions` row.
public struct DecisionView: Codable, Sendable, Equatable {
    public let id: Int64
    public let eventID: Int64
    public let topicKeywords: [String]
    public let reasoningExcerpt: String
    public let confidence: Double
    public let detectedAtMs: Int64

    public init(
        id: Int64,
        eventID: Int64,
        topicKeywords: [String],
        reasoningExcerpt: String,
        confidence: Double,
        detectedAtMs: Int64
    ) {
        self.id = id
        self.eventID = eventID
        self.topicKeywords = topicKeywords
        self.reasoningExcerpt = reasoningExcerpt
        self.confidence = confidence
        self.detectedAtMs = detectedAtMs
    }
}

/// `leaf_get_decision` payload — single decision + originating event projection
/// + outbound `event_links` rows from that event (typically PR / Linear refs).
public struct DecisionDetail: Codable, Sendable {
    public let decision: DecisionView
    public let originatingEvent: ActivityEvent
    public let linksToImplementation: [LinkView]

    public init(
        decision: DecisionView,
        originatingEvent: ActivityEvent,
        linksToImplementation: [LinkView]
    ) {
        self.decision = decision
        self.originatingEvent = originatingEvent
        self.linksToImplementation = linksToImplementation
    }
}

/// Slim projection of one `open_questions` row.
public struct OpenQuestionView: Codable, Sendable, Equatable {
    public let id: Int64
    public let eventID: Int64
    public let questionExcerpt: String
    public let alternatives: [String]?
    public let slackThreadTS: String?
    public let linearIssueRef: String?
    public let githubPRRef: String?
    public let resolvedByEventID: Int64?
    public let openedAtMs: Int64
    public let resolvedAtMs: Int64?

    public init(
        id: Int64,
        eventID: Int64,
        questionExcerpt: String,
        alternatives: [String]?,
        slackThreadTS: String?,
        linearIssueRef: String?,
        githubPRRef: String?,
        resolvedByEventID: Int64?,
        openedAtMs: Int64,
        resolvedAtMs: Int64?
    ) {
        self.id = id
        self.eventID = eventID
        self.questionExcerpt = questionExcerpt
        self.alternatives = alternatives
        self.slackThreadTS = slackThreadTS
        self.linearIssueRef = linearIssueRef
        self.githubPRRef = githubPRRef
        self.resolvedByEventID = resolvedByEventID
        self.openedAtMs = openedAtMs
        self.resolvedAtMs = resolvedAtMs
    }
}

/// Slim projection of one `blockers` row.
public struct BlockerView: Codable, Sendable, Equatable {
    public let id: Int64
    public let targetKind: String
    public let targetRef: String
    public let blockerKind: String
    public let blockerExcerpt: String?
    public let detectedByEventID: Int64?
    public let startedAtMs: Int64
    public let resolvedAtMs: Int64?
    public let resolvedByEventID: Int64?

    public init(
        id: Int64,
        targetKind: String,
        targetRef: String,
        blockerKind: String,
        blockerExcerpt: String?,
        detectedByEventID: Int64?,
        startedAtMs: Int64,
        resolvedAtMs: Int64?,
        resolvedByEventID: Int64?
    ) {
        self.id = id
        self.targetKind = targetKind
        self.targetRef = targetRef
        self.blockerKind = blockerKind
        self.blockerExcerpt = blockerExcerpt
        self.detectedByEventID = detectedByEventID
        self.startedAtMs = startedAtMs
        self.resolvedAtMs = resolvedAtMs
        self.resolvedByEventID = resolvedByEventID
    }
}

/// Slim projection of one `event_links` row. Mirrors the public `EventLink`
/// value type but omits `createdAtMs` for response compactness — consumers care
/// about the (link_kind, target_kind, target_ref) triple, not provenance ts.
public struct LinkView: Codable, Sendable, Equatable {
    public let fromEventID: Int64
    public let linkKind: String
    public let targetKind: String
    public let targetRef: String
    public let confidence: Double

    public init(
        fromEventID: Int64,
        linkKind: String,
        targetKind: String,
        targetRef: String,
        confidence: Double
    ) {
        self.fromEventID = fromEventID
        self.linkKind = linkKind
        self.targetKind = targetKind
        self.targetRef = targetRef
        self.confidence = confidence
    }
}

/// `leaf_current_work.inProgressLinearTicket` shape — ref + display title + state.
public struct LinearTicketRef: Codable, Sendable, Equatable {
    public let issueRef: String
    public let title: String?
    public let stateName: String?

    public init(issueRef: String, title: String?, stateName: String?) {
        self.issueRef = issueRef
        self.title = title
        self.stateName = stateName
    }
}

/// `leaf_current_work.lastCommit` shape — derived from latest `gh_commit_pushed`
/// payload. `pushedAtMs` mirrors `events.ts` for that row.
public struct CommitRef: Codable, Sendable, Equatable {
    public let sha: String?
    public let message: String?
    public let branch: String?
    public let pushedAtMs: Int64?

    public init(sha: String?, message: String?, branch: String?, pushedAtMs: Int64?) {
        self.sha = sha
        self.message = message
        self.branch = branch
        self.pushedAtMs = pushedAtMs
    }
}

/// `QueryActivityResponse.truncationNote` carrier. Currently only one reason
/// (`"byte_budget"`); leaving as a string keeps room for future
/// `"event_count"` / `"period_too_wide"` without an enum migration.
public struct TruncationNote: Codable, Sendable, Equatable {
    public let reason: String
    public let originalCount: Int
    public let returnedCount: Int
    public let oldestReturnedTsMs: Int64?

    public init(
        reason: String,
        originalCount: Int,
        returnedCount: Int,
        oldestReturnedTsMs: Int64?
    ) {
        self.reason = reason
        self.originalCount = originalCount
        self.returnedCount = returnedCount
        self.oldestReturnedTsMs = oldestReturnedTsMs
    }
}
