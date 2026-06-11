import Foundation
import GRDB

/// Use-case rebuild Track A5 — per-source capture coverage. Surfaces consume
/// this to render HONEST empty states: "Search found nothing" on a machine
/// with no Slack connection and no watched repo folder is a coverage problem,
/// not an absence of results — say so and point at the fix.
public enum CoverageAction: Sendable, Equatable {
  case connectProvider(String)
  case addWatchedRepoFolder
}

public struct MemoryCoverageReport: Sendable, Equatable {
  public struct SourceCoverage: Sendable, Equatable {
    public let source: String
    public let connected: Bool
    /// FTS-indexed body rows attributable to this source within the window.
    public let bodiesIndexed: Int
    /// Newest event ts for the source — window-independent freshness signal.
    public let lastEventTsMs: Int64?
    public let suggestedAction: CoverageAction?
  }

  public let sources: [SourceCoverage]
  public let totalBodiesIndexed: Int
  /// Repos seen in GitHub activity but not polled locally — candidates for
  /// the "Add repo folder" CTA (commit messages only flow via local git).
  public let suggestedRepos: [String]
}

public enum MemoryCoverageReporter {

  /// body_kind → source attribution.
  private static let bodyKindSource: [String: String] = [
    Schema.BodyKinds.commitMsg: "github",  // refined below for git_local
    Schema.BodyKinds.ghPR: "github",
    Schema.BodyKinds.ghIssueComment: "github",
    Schema.BodyKinds.ghPRReviewComment: "github",
    Schema.BodyKinds.ghGistDescription: "github",
    Schema.BodyKinds.ghReleaseBody: "github",
    Schema.BodyKinds.ghDeploymentDescription: "github",
    Schema.BodyKinds.linearDesc: "linear",
    Schema.BodyKinds.linearComment: "linear",
    Schema.BodyKinds.linearNotificationTitle: "linear",
    Schema.BodyKinds.slackMsg: "slack",
    Schema.BodyKinds.slackThreadParent: "slack",
    Schema.BodyKinds.slackThreadReply: "slack",
    Schema.BodyKinds.slackCanvasTitle: "slack",
    Schema.BodyKinds.slackBookmarkTitle: "slack",
  ]

  public static func report(
    lastDays: Int,
    nowMs: Int64,
    in db: GRDB.Database
  ) throws -> MemoryCoverageReport {
    let windowStart = nowMs - Int64(lastDays) * 86_400_000

    let connectedProviders = Set(try String.fetchAll(
      db, sql: "SELECT provider FROM \(Schema.Integrations.tableName)"))
    let gitLocalConnected = (try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM collector_offsets WHERE collector_id = ?",
      arguments: [GitLogCollector.collectorID]) ?? 0) > 0

    // Indexed bodies per source within the window. git_local split from
    // github by the originating event_kind.
    var bodies: [String: Int] = [:]
    let bodyRows = try Row.fetchAll(db, sql: """
      SELECT m.body_kind AS body_kind,
             json_extract(e.payload_json, '$.event_kind') AS event_kind,
             COUNT(*) AS n
        FROM events_fts_meta m JOIN events e ON e.id = m.event_id
       WHERE e.ts >= ?
       GROUP BY m.body_kind, event_kind
      """, arguments: [windowStart])
    for row in bodyRows {
      let bodyKind: String = row["body_kind"]
      let eventKind: String? = row["event_kind"]
      let n: Int = row["n"]
      let source: String
      if eventKind == GitLogCollector.eventKind {
        source = "git_local"
      } else if let mapped = bodyKindSource[bodyKind] {
        source = mapped
      } else {
        source = "local"
      }
      bodies[source, default: 0] += n
    }

    func lastTs(forKinds kindsLike: String) throws -> Int64? {
      try Int64.fetchOne(db, sql: """
        SELECT MAX(ts) FROM events
         WHERE json_extract(payload_json, '$.event_kind') LIKE ?
        """, arguments: [kindsLike])
    }

    var sources: [MemoryCoverageReport.SourceCoverage] = []
    for provider in ["github", "linear", "slack"] {
      let connected = connectedProviders.contains(provider)
      let prefix = provider == "github" ? "gh\\_%" : "\(provider)%"
      sources.append(.init(
        source: provider,
        connected: connected,
        bodiesIndexed: bodies[provider] ?? 0,
        lastEventTsMs: try Int64.fetchOne(db, sql: """
          SELECT MAX(ts) FROM events
           WHERE json_extract(payload_json, '$.event_kind') LIKE ? ESCAPE '\\'
              OR (? = 'linear' AND json_extract(payload_json, '$.event_kind') IN
                  ('issue_updated', 'status_transition'))
          """, arguments: [prefix, provider]),
        suggestedAction: connected ? nil : .connectProvider(provider)
      ))
    }
    sources.append(.init(
      source: "git_local",
      connected: gitLocalConnected,
      bodiesIndexed: bodies["git_local"] ?? 0,
      lastEventTsMs: try lastTs(forKinds: GitLogCollector.eventKind),
      suggestedAction: gitLocalConnected ? nil : .addWatchedRepoFolder
    ))

    // Repo suggestions: GitHub-activity repos that local polling doesn't cover.
    let activityRepos = Set(try String.fetchAll(db, sql: """
      SELECT DISTINCT json_extract(payload_json, '$.repo') FROM events
       WHERE json_extract(payload_json, '$.event_kind') LIKE 'gh\\_%' ESCAPE '\\'
         AND json_extract(payload_json, '$.repo') IS NOT NULL
         AND ts >= ?
      """, arguments: [windowStart]))
    let polledRepoNames = Set(try String.fetchAll(db, sql: """
      SELECT DISTINCT json_extract(payload_json, '$.repo') FROM events
       WHERE json_extract(payload_json, '$.event_kind') = ?
         AND json_extract(payload_json, '$.repo') IS NOT NULL
      """, arguments: [GitLogCollector.eventKind]))
    let suggestions = activityRepos.subtracting(polledRepoNames).sorted()

    return MemoryCoverageReport(
      sources: sources,
      totalBodiesIndexed: bodies.values.reduce(0, +),
      suggestedRepos: suggestions
    )
  }
}
