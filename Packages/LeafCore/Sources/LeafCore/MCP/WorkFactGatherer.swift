import Foundation
import GRDB

/// Track AI Coworker P1 — on-device retrieval for the Default Q&A path
/// (clusters 1–2: recap + resume). Produces `[EgressEvent]` and stops; the
/// caller runs them through `LLMPolicy.makeContext` (the sole opaque boundary
/// constructor) → `Summarizer`. The gatherer NEVER builds a `PromptSafeContext`
/// and NEVER calls an LLM — single-boundary discipline (§13.2).
///
/// It emits three families, every value a scalar string fenced by the egress
/// allow-list (§8.1):
///   * `recap_metrics` (cluster 1) — identity-free holistic magnitudes (focus,
///     ai-ratio, peak hour, files-touched COUNT, per-provider counts). No app
///     identity, no file paths → nothing the bucket-1 filter would need to
///     backstop (N-1).
///   * `blocker_fact` / `open_question_fact` / `where_stopped_fact` (cluster 2) —
///     STRUCTURED detector columns only; free-text excerpts are escalation-only
///     (P3) and never emitted here.
///   * real self-authored events (`gh_pr_opened` / `gh_issue_opened` /
///     `gh_branch_created`, ≤`selfAuthoredCap`) whose full stored payload is fed
///     to the boundary, which carves the ≤140 `self_authored_*` label and drops
///     the rest. `gh_commit_pushed` is excluded (pushing ≠ authoring — CR-1).
///
/// This is distinct from `QueryEngine` (which returns capped bodies to the
/// user's own AI client) and must never reuse its body-bearing projection.
public struct WorkFactGatherer: Sendable {
  public let dbURL: URL
  public let dbConfig: DatabaseConfig
  public let dbEncryption: EncryptionOptions?
  /// Inject the insights factory as a closure so the gatherer opens ONE read
  /// handle and builds insights on it (no second handle, no global-state test
  /// coupling). Prod default resolves `ProdInsights` via the registered factory.
  public let insightsProvider: @Sendable (Database) -> any DerivedInsights

  /// Bound on real self-authored events fed to the prompt (cost / latency /
  /// truncation guard — N-3).
  public static let selfAuthoredCap = 50

  /// Detector facts older than this are stale (mirrors `QueryEngine`).
  static let whereStoppedFreshnessWindowMs: Int64 = 24 * 60 * 60 * 1000

  /// Bound on cross_link_fact events fed to the prompt (cost / latency guard).
  static let crossLinkCap = 100

  /// P3 — bound on the number of explicitly-selected events an escalation may
  /// send (cost guard; the user / AI-client names these ids — §13.4 consent act).
  public static let escalationEventIDCap = 50

  /// from_ref priority — SAFE structural ids only. NEVER `branch`/`title`
  /// (free text, fenced by the boundary; CR-3). First present wins.
  private static let crossLinkFromRefKeys = ["pr_number", "number", "issue_identifier", "sha"]

  private static let selfAuthoredKinds = ["gh_pr_opened", "gh_issue_opened", "gh_branch_created"]
  private static let countedKinds = [
    "gh_commit_pushed", "gh_pr_opened", "gh_issue_opened", "gh_branch_created",
  ]

  public init(
    dbURL: URL,
    dbConfig: DatabaseConfig,
    dbEncryption: EncryptionOptions?,
    insightsProvider: @escaping @Sendable (Database) -> any DerivedInsights = {
      DerivedInsightsFactory.make(database: $0)
    }
  ) {
    self.dbURL = dbURL
    self.dbConfig = dbConfig
    self.dbEncryption = dbEncryption
    self.insightsProvider = insightsProvider
  }

  /// Recap metrics are period-scoped; detector facts are current-unresolved
  /// (resume framing). Never throws on no-data (returns the recap event with
  /// whatever computed); throws only on DB-open failure.
  public func gather(period: DateInterval, nowMs: Int64) throws -> [EgressEvent] {
    let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
    let insights = insightsProvider(db)

    // Cluster-1 magnitudes — graceful on stub/no-data (StubInsights throws
    // .notImplemented; `try?` degrades to omitted/zero, never aborts gather).
    let focus = (try? insights.focusSessions(period: period)) ?? []
    let focusTotalSec = Int(focus.reduce(0.0) { $0 + $1.duration }.rounded())
    let aiRatioPct = Int((((try? insights.aiRatio(period: period)) ?? 0) * 100).rounded())
    let peakHour = (try? insights.peakProductivityHour()).flatMap { $0 }
    let filesTouchedCount = ((try? insights.filesTouched(period: period)) ?? []).count

    // Cluster-4 trend/latency — computed on the same `insights` handle as the
    // cluster-1 magnitudes above (each read `try?`-graceful). trend is always
    // emitted (streaks default 0); latency only when ≥1 sample exists.
    let trendEvent = Self.trendMetrics(period: period, nowMs: nowMs, insights: insights)
    let latencyEvent = Self.latencyMetrics(period: period, insights: insights)

    let startMs = Int64(period.start.timeIntervalSince1970 * 1000)
    let endMs = Int64(period.end.timeIntervalSince1970 * 1000)

    return try db.readSQL { rawDB -> [EgressEvent] in
      let counts = try Self.periodCounts(startMs: startMs, endMs: endMs, in: rawDB)
      let blockerEvents = try Self.blockerFacts(in: rawDB)
      let questionEvents = try Self.openQuestionFacts(in: rawDB)
      let whereStopped = try Self.whereStoppedFact(nowMs: nowMs, in: rawDB)
      let selfAuthored = try Self.selfAuthoredEvents(startMs: startMs, endMs: endMs, in: rawDB)
      let crossLinks = try Self.crossLinkFacts(startMs: startMs, endMs: endMs, in: rawDB)

      var recap: [String: String] = [
        "focus_session_count": String(focus.count),
        "focus_total_seconds": String(focusTotalSec),
        "ai_ratio_pct": String(aiRatioPct),
        "files_touched_count": String(filesTouchedCount),
        "commit_count": String(counts["gh_commit_pushed"] ?? 0),
        "pr_opened_count": String(counts["gh_pr_opened"] ?? 0),
        "issue_opened_count": String(counts["gh_issue_opened"] ?? 0),
        "branch_created_count": String(counts["gh_branch_created"] ?? 0),
        "open_question_count": String(questionEvents.count),
        "blocker_count": String(blockerEvents.count),
      ]
      if let peakHour { recap["peak_productivity_hour"] = String(peakHour) }

      let recapEvent = EgressEvent(
        timestamp: period.end, kind: "recap_metrics", bundleID: nil, payload: recap)

      // Built step-by-step (a single long `+` chain over-taxes the type-checker).
      var out: [EgressEvent] = [recapEvent]
      out.append(contentsOf: blockerEvents)
      out.append(contentsOf: questionEvents)
      if let whereStopped { out.append(whereStopped) }
      out.append(contentsOf: selfAuthored)
      out.append(contentsOf: crossLinks)
      out.append(trendEvent)
      if let latencyEvent { out.append(latencyEvent) }
      return out
    }
  }

  /// P3 escalation retrieval — fetch the explicitly-selected events' FULL
  /// payloads (including `body`) by id, carrying `bundleID` FROM THE `bundle_id`
  /// COLUMN so the boundary's bucket-1 drop works (CR-5 — the other gather
  /// helpers use `bundleID:nil`; this one must NOT). Distinct from
  /// `QueryEngine.projectEvents` (the trusted-client capped-body wire — never
  /// reuse as egress); the caller runs these through `LLMPolicy.makeEscalation`
  /// (bucket-1 drop + cap + provenance) before any wire. Scoped to the top-level
  /// `body` key (covers GitHub PR/issue comments + commits + Linear desc + Slack
  /// thread parent); array-aggregated bodies are a documented follow-up.
  public func gatherSelectedBodies(eventIDs: [Int64]) throws -> [EgressEvent] {
    guard !eventIDs.isEmpty else { return [] }
    let capped = Array(eventIDs.prefix(Self.escalationEventIDCap))
    let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
    return try db.readSQL { rawDB -> [EgressEvent] in
      let placeholders = capped.map { _ in "?" }.joined(separator: ",")
      let rows = try Row.fetchAll(
        rawDB,
        sql: """
          SELECT id, ts, signal_type, bundle_id, payload_json
            FROM events
           WHERE id IN (\(placeholders))
           ORDER BY ts ASC
          """,
        arguments: StatementArguments(capped))
      return rows.compactMap { row in
        let ts: Int64 = row["ts"] ?? 0
        let bundleID: String? = row["bundle_id"]
        let json: String = (row["payload_json"] as String?) ?? "{}"
        guard let payload = Self.decodePayload(json) else { return nil }
        let kind = payload["event_kind"] ?? (row["signal_type"] as String?) ?? "event"
        return EgressEvent(
          timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
          kind: kind, bundleID: bundleID, payload: payload)
      }
    }
  }

  // MARK: - SQL helpers (structured columns only — never *_excerpt)

  private static func periodCounts(
    startMs: Int64, endMs: Int64, in db: GRDB.Database
  ) throws -> [String: Int] {
    let placeholders = countedKinds.map { _ in "?" }.joined(separator: ",")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT json_extract(payload_json, '$.event_kind') AS k, COUNT(*) AS c
          FROM events
         WHERE ts BETWEEN ? AND ?
           AND json_extract(payload_json, '$.event_kind') IN (\(placeholders))
         GROUP BY k
        """,
      arguments: StatementArguments([startMs, endMs] + countedKinds))
    var out: [String: Int] = [:]
    for row in rows {
      if let k: String = row["k"] { out[k] = row["c"] as Int }
    }
    return out
  }

  private static func blockerFacts(in db: GRDB.Database) throws -> [EgressEvent] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT target_kind, target_ref, blocker_kind, started_at_ms
          FROM blockers
         WHERE resolved_at_ms IS NULL
         ORDER BY started_at_ms DESC LIMIT 10
        """)
    return rows.compactMap { row in
      guard let targetRef: String = row["target_ref"] else { return nil }
      var payload: [String: String] = ["target_ref": targetRef]
      if let tk: String = row["target_kind"] { payload["target_kind"] = tk }
      if let bk: String = row["blocker_kind"] { payload["blocker_kind"] = bk }
      let startedAtMs: Int64 = row["started_at_ms"] ?? 0
      payload["started_at_ms"] = String(startedAtMs)
      return EgressEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000.0),
        kind: "blocker_fact", bundleID: nil, payload: payload)
    }
  }

  private static func openQuestionFacts(in db: GRDB.Database) throws -> [EgressEvent] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT linear_issue_ref, github_pr_ref, slack_thread_ts, opened_at_ms
          FROM open_questions
         WHERE resolved_at_ms IS NULL
         ORDER BY opened_at_ms DESC LIMIT 20
        """)
    return rows.map { row in
      var payload: [String: String] = [:]
      if let v: String = row["linear_issue_ref"] { payload["linear_issue_ref"] = v }
      if let v: String = row["github_pr_ref"] { payload["github_pr_ref"] = v }
      if let v: String = row["slack_thread_ts"] { payload["slack_thread_ts"] = v }
      let openedAtMs: Int64 = row["opened_at_ms"] ?? 0
      payload["opened_at_ms"] = String(openedAtMs)
      return EgressEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(openedAtMs) / 1000.0),
        kind: "open_question_fact", bundleID: nil, payload: payload)
    }
  }

  private static func whereStoppedFact(
    nowMs: Int64, in db: GRDB.Database
  ) throws -> EgressEvent? {
    guard let row = try WhereStoppedLogStore.latest(in: db),
      let generatedAtMs: Int64 = row["generated_at_ms"],
      nowMs - generatedAtMs <= whereStoppedFreshnessWindowMs
    else { return nil }

    let wip: WipSignals
    if let wipJSON: String = row["wip_signals_json"],
      let data = wipJSON.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(WipSignals.self, from: data) {
      wip = decoded
    } else {
      wip = WipSignals(commitWip: false, ciFailing: false, midEdit: false)
    }
    // STRUCTURED only — the where_stopped excerpt is escalation-only (P3).
    let payload: [String: String] = [
      "wip_commit": String(wip.commitWip),
      "wip_ci_failing": String(wip.ciFailing),
      "wip_mid_edit": String(wip.midEdit),
      "generated_at_ms": String(generatedAtMs),
    ]
    return EgressEvent(
      timestamp: Date(timeIntervalSince1970: TimeInterval(generatedAtMs) / 1000.0),
      kind: "where_stopped_fact", bundleID: nil, payload: payload)
  }

  private static func selfAuthoredEvents(
    startMs: Int64, endMs: Int64, in db: GRDB.Database
  ) throws -> [EgressEvent] {
    let placeholders = selfAuthoredKinds.map { _ in "?" }.joined(separator: ",")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT ts, payload_json FROM events
         WHERE ts BETWEEN ? AND ?
           AND json_extract(payload_json, '$.event_kind') IN (\(placeholders))
           AND json_extract(payload_json, '$.authored_by_viewer') = 'true'
         ORDER BY ts DESC LIMIT \(selfAuthoredCap)
        """,
      arguments: StatementArguments([startMs, endMs] + selfAuthoredKinds))
    return rows.compactMap { row in
      let ts: Int64 = row["ts"] ?? 0
      let json: String = (row["payload_json"] as String?) ?? "{}"
      guard let payload = Self.decodePayload(json),
        let kind = payload["event_kind"]
      else { return nil }
      // Full stored payload → boundary carves the ≤140 self_authored_* label and
      // drops everything else (the gatherer never pre-filters bodies).
      return EgressEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
        kind: kind, bundleID: nil, payload: payload)
    }
  }

  /// Cluster 3b — cross-provider links from the `event_links` graph. Two
  /// target kinds ship: `linear_issue` (target_ref is a work-namespace Linear ID
  /// like "LEAF-88", verbatim) and `github_pr` (P3 — target_ref is the leaky
  /// `owner/repo/pull/N` slug, NORMALIZED to bare `#N` via `PRRefNormalizer`,
  /// fail-closed on an unrecognized shape; this also de-leaks the existing
  /// PR-URL-in-Slack links). `github_user` (3rd-party login) and `calendar_event`
  /// are excluded — never trust target_ref values past this filter (CR-2). The
  /// from-side is identified by a SAFE structural id (`from_ref`), never
  /// branch/title (CR-3). No `confidence` (moat constant).
  private static func crossLinkFacts(
    startMs: Int64, endMs: Int64, in db: GRDB.Database
  ) throws -> [EgressEvent] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT el.link_kind   AS link_kind,
               el.target_kind AS target_kind,
               el.target_ref  AS target_ref,
               e.ts           AS ts,
               json_extract(e.payload_json, '$.event_kind')       AS from_kind,
               json_extract(e.payload_json, '$.pr_number')        AS pr_number,
               json_extract(e.payload_json, '$.number')           AS number,
               json_extract(e.payload_json, '$.issue_identifier') AS issue_identifier,
               json_extract(e.payload_json, '$.sha')              AS sha
          FROM event_links el
          JOIN events e ON e.id = el.from_event_id
         WHERE e.ts BETWEEN ? AND ?
           AND el.target_kind IN (?, ?)
         ORDER BY e.ts DESC
         LIMIT \(crossLinkCap)
        """,
      arguments: [startMs, endMs, Schema.TargetKinds.linearIssue, Schema.TargetKinds.githubPR])
    return rows.compactMap { row in
      guard let targetRef: String = row["target_ref"], !targetRef.isEmpty else { return nil }
      let targetKind: String = row["target_kind"] ?? Schema.TargetKinds.linearIssue
      // De-leak per target_kind: linear_issue ships verbatim (bare LEAF-NN);
      // github_pr is normalized owner/repo/pull/N → #N (strips the org/repo slug),
      // fail-closed (unrecognized shape → drop). Nothing else is trusted past the
      // IN-filter.
      let shippedRef: String
      switch targetKind {
      case Schema.TargetKinds.linearIssue:
        shippedRef = targetRef
      case Schema.TargetKinds.githubPR:
        guard let bare = PRRefNormalizer.bareNumber(fromCanonicalPRRef: targetRef) else { return nil }
        shippedRef = bare
      default:
        return nil
      }
      var payload: [String: String] = [
        "target_kind": targetKind,
        "target_ref": shippedRef,
      ]
      if let linkKind: String = row["link_kind"] { payload["link_kind"] = linkKind }
      if let fromKind = coerceString(row, "from_kind") { payload["from_kind"] = fromKind }
      // from_ref: first present SAFE structural id — never branch/title (CR-3).
      for key in crossLinkFromRefKeys {
        if let ref = coerceString(row, key) {
          payload["from_ref"] = ref
          break
        }
      }
      let ts: Int64 = row["ts"] ?? 0
      return EgressEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
        kind: "cross_link_fact", bundleID: nil, payload: payload)
    }
  }

  /// Read a (possibly json_extract'd) column as a non-empty String regardless of
  /// SQLite affinity — payload values are JSON strings here, but json_extract can
  /// surface a numeric value as INTEGER/REAL affinity (CR-15). NULL/empty → nil.
  private static func coerceString(_ row: GRDB.Row, _ column: String) -> String? {
    let value: DatabaseValue = row[column]
    let s: String?
    switch value.storage {
    case .string(let str): s = str
    case .int64(let i): s = String(i)
    // Integral REAL affinity (e.g. a json number id) → no trailing ".0".
    case .double(let d): s = d == d.rounded() ? String(Int64(d)) : String(d)
    case .null, .blob: s = nil
    }
    guard let s, !s.isEmpty else { return nil }
    return s
  }

  /// Cluster 4 — identity-free trend magnitudes (mirrors recap_metrics: no app
  /// identity, no paths, no source NAMES — only counts/deltas/streaks/durations).
  /// Trailing-7d: `wow_delta_pct`, `*_streak`, `active_days_in_row`.
  /// Period-scoped: completion rate, uninterrupted window, Linear transition
  /// counts. Every read is `try?`-graceful (stub/no-data → key omitted or 0).
  private static func trendMetrics(
    period: DateInterval, nowMs: Int64, insights: any DerivedInsights
  ) -> EgressEvent {
    var p: [String: String] = [:]
    // Trailing-7d / global.
    if let wow = try? insights.weekOverWeekDelta() {
      p["wow_delta_pct"] = String(Int((wow * 100).rounded()))
    }
    let now = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0)
    let weekly = (try? insights.weeklyMetrics(now: now)) ?? .empty
    p["commit_streak"] = String(weekly.commitStreak)
    p["issue_close_streak"] = String(weekly.issueCloseStreak)
    p["huddle_streak"] = String(weekly.huddleStreak)
    p["focus_session_streak"] = String(weekly.focusSessionStreak)
    p["heavy_pulse_streak"] = String(weekly.heavyPulseStreak)
    if let dws = try? insights.deepWorkStreak() {
      p["deep_work_streak_days"] = String(dws.days)
      p["deep_work_streak_seconds"] = String(Int(dws.totalSeconds.rounded()))
    }
    if let active = try? insights.activeDaysInRow() {
      p["active_days_in_row"] = String(active)
    }
    // Period-scoped.
    if let rate = try? insights.linearCompletionRate(period: period) {
      p["linear_completion_rate_pct"] = String(Int((rate * 100).rounded()))
    }
    if let win = try? insights.longestUninterruptedWindow(period: period) {
      p["uninterrupted_window_seconds"] = String(win.durationSeconds)
      // COUNT only — never the source names (CR-5).
      p["uninterrupted_window_sources_count"] = String(win.sourcesActiveInPeriod.count)
    }
    if let tr = try? insights.linearTransitions(period: period) {
      p["linear_started_count"] = String(tr.started)
      p["linear_completed_count"] = String(tr.completed)
      p["linear_canceled_count"] = String(tr.canceled)
      p["linear_reopened_count"] = String(tr.reopened)
    }
    return EgressEvent(timestamp: period.end, kind: "trend_metrics", bundleID: nil, payload: p)
  }

  /// Cluster 4 — latency distribution magnitudes (median/max seconds + sample
  /// count) per provider metric. A metric's keys are omitted when its
  /// `LatencyStats` is nil (no samples); the whole event is omitted when empty.
  private static func latencyMetrics(
    period: DateInterval, insights: any DerivedInsights
  ) -> EgressEvent? {
    var p: [String: String] = [:]
    func put(_ prefix: String, _ stats: LatencyStats?) {
      guard let stats else { return }
      p["\(prefix)_median_sec"] = String(stats.medianSeconds)
      p["\(prefix)_max_sec"] = String(stats.maxSeconds)
      p["\(prefix)_sample_count"] = String(stats.sampleCount)
    }
    let gh = try? insights.githubActivity(period: period)
    put("pr_cycle", gh?.prCycleStats)
    put("review_delay", gh?.reviewDelayStats)
    put("linear_completion", (try? insights.linearActivity(period: period))?.completionDurationStats)
    put("huddle_session", (try? insights.slackActivity(period: period))?.huddleSessionStats)
    guard !p.isEmpty else { return nil }
    return EgressEvent(timestamp: period.end, kind: "latency_metrics", bundleID: nil, payload: p)
  }

  /// Decode a stored `payload_json` object to `[String: String]`. String values
  /// pass through; scalar (number/bool) values are stringified; nested
  /// arrays/objects are dropped (they are body fields the boundary fences anyway).
  private static func decodePayload(_ json: String) -> [String: String]? {
    guard let data = json.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    var out: [String: String] = [:]
    for (key, value) in obj {
      switch value {
      case let s as String: out[key] = s
      case let n as NSNumber: out[key] = n.stringValue
      default: continue  // arrays / objects / null → drop
      }
    }
    return out
  }
}
