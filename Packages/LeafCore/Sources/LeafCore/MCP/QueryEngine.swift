import Foundation
import GRDB
import os

/// Phase Track-1 D3 — query-side composition over events + FTS + links +
/// detector tables, exposed to MCP tool handlers.
///
/// Three composition methods:
///   * `queryActivity(period:filter:)` — period+filter scoped activity feed,
///     with detector outputs + cross-source links + on-the-fly absence flags.
///     SQL `LIMIT 200` + post-serialize 64KB byte budget with oldest-event
///     trim and `truncationNote`.
///   * `getDecision(topic:period:)` — FTS over event bodies, ranked by
///     decision confidence + recency; returns top-1 with originating event
///     projection + outbound links.
///   * `currentWork(nowMs:)` — latest-event projections for the
///     `leaf_current_work` MCP tool.
///
/// Read-only: each call opens `Database.openForRead(...)` per existing 12 MCP
/// tools' pattern. `bodyExcerptCharCap` defaults to 500 (substrate); production
/// callers thread the moat-supplied cap through.
///
/// Phase 2.3.C.4 split — implementation methods live in three extension
/// files: `QueryEngine+QueryActivity.swift`, `QueryEngine+GetDecision.swift`,
/// `QueryEngine+CurrentWork.swift`, with shared row→view mappers + event
/// projection in `QueryEngine+Projection.swift`.
public struct QueryEngine: Sendable {

    static let log = Logger(subsystem: "tech.gundem.leaf.core", category: "query-engine")

    /// Hard SQL `LIMIT` for `events[]` projection. Backstop ahead of byte-budget
    /// trim so we never decode 100k events to immediately drop them.
    static let sqlEventLimit = 200

    /// MCP per-response byte budget. AI clients tend to reject larger payloads
    /// outright; we trim deterministically (oldest-first) and surface a
    /// `truncationNote` so the caller knows. Measured against `.sortedKeys`
    /// canonical encoding — the MCP server uses the same shape so the budget
    /// holds end-to-end.
    static let byteBudget = 65_536

    /// Candidate-event cap for FTS-routed `getDecision` topic match. Decisions
    /// table has UNIQUE event_id, so 50 candidates → at most 50 decision rows
    /// to rank by confidence/recency.
    static let decisionTopicCandidateLimit = 50

    /// `currentWork.whereStopped` only surfaces the latest log row if generated
    /// within this window — older entries are stale and worse than nothing.
    static let whereStoppedFreshnessWindowMs: Int64 = 24 * 60 * 60 * 1000

    public let dbURL: URL
    public let dbConfig: DatabaseConfig
    public let dbEncryption: EncryptionOptions?
    public let detectorMoat: DetectorMoat
    public let bodyExcerptCharCap: Int

    public init(
        dbURL: URL,
        dbConfig: DatabaseConfig,
        dbEncryption: EncryptionOptions?,
        detectorMoat: DetectorMoat,
        bodyExcerptCharCap: Int = 500
    ) {
        self.dbURL = dbURL
        self.dbConfig = dbConfig
        self.dbEncryption = dbEncryption
        self.detectorMoat = detectorMoat
        self.bodyExcerptCharCap = bodyExcerptCharCap
    }
}

// MARK: - LinkView <- EventLink

extension LinkView {
    /// Convenience init for translating the public substrate `EventLink`
    /// (carries `createdAtMs`) into the response-side `LinkView` (drops it).
    public init(from link: EventLink) {
        self.init(
            fromEventID: link.fromEventID,
            linkKind: link.linkKind,
            targetKind: link.targetKind,
            targetRef: link.targetRef,
            confidence: link.confidence
        )
    }
}
