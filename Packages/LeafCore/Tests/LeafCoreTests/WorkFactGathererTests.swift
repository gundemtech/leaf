// Track AI Coworker P1 — WorkFactGatherer: retrieval → [EgressEvent] for the
// Default Q&A path. Asserts the gathered events, that the egress boundary drops
// excerpts/paths and carves self-authored labels, the self-authored cap, and
// that no gathered event carries an app bundleID (bucket-1-safe by construction).

import GRDB
import XCTest

@testable import LeafCore

final class WorkFactGathererTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!
  private let nowMs: Int64 = 10_000_000
  private let period = DateInterval(
    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-gather-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Fixtures

  private struct FakeInsights: DerivedInsights {
    func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { [] }
    func focusSessions(period: DateInterval) throws -> [FocusSession] {
      let s = Date(timeIntervalSince1970: 0)
      return [
        FocusSession(bundleID: "com.apple.dt.Xcode", start: s, end: s.addingTimeInterval(3600)),
        FocusSession(
          bundleID: "com.apple.dt.Xcode", start: s.addingTimeInterval(3600),
          end: s.addingTimeInterval(7200)),
      ]
    }
    func contextSwitchRate(period: DateInterval) throws -> Double { 0 }
    func deepWorkStreak() throws -> DeepWorkStreak { DeepWorkStreak(days: 0, totalSeconds: 0) }
    func peakProductivityHour() throws -> Int? { 15 }
    func filesTouched(period: DateInterval) throws -> [String] {
      ["/Users/alice/secret-acquisition.md", "/Users/alice/b.swift", "/Users/alice/c.txt"]
    }
    func aiRatio(period: DateInterval) throws -> Double { 0.4 }
    func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown { .empty }
    func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown { .empty }
    func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown { .empty }
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { 0 }
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { 0 }
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { [] }
    func weekOverWeekDelta() throws -> Double? { nil }
    func activeDaysInRow() throws -> Int { 0 }
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot? { nil }
  }

  private func openWriter() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func writeEvent(
    _ db: LeafCore.Database, tsMs: Int64, signalType: SignalType = .action,
    bundleID: String? = nil, payload: [String: String]
  ) throws {
    try db.write(
      RawEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
        signalType: signalType, bundleID: bundleID, payload: payload))
  }

  private func makeGatherer(insights: any DerivedInsights = FakeInsights()) -> WorkFactGatherer {
    WorkFactGatherer(
      dbURL: dbURL, dbConfig: .weakDefaults, dbEncryption: .deterministicTest,
      insightsProvider: { _ in insights })
  }

  /// Run the gathered events through the egress boundary and flatten to a string.
  private func renderThroughBoundary(_ events: [EgressEvent]) -> String {
    LLMPolicy().makeContext(events: events).facts.map { fact in
      let fields = fact.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: ";")
      return "\(fact.kind)|\(fields)"
    }.joined(separator: "\n")
  }

  // MARK: - 1. recap_metrics: identity-free magnitudes; paths never ship.

  func testRecapMetrics_magnitudesOnly_noPaths() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 1_000, payload: ["event_kind": "gh_commit_pushed", "sha": "a"])
    try writeEvent(db, tsMs: 2_000, payload: ["event_kind": "gh_commit_pushed", "sha": "b"])
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)

    let recap = try XCTUnwrap(events.first { $0.kind == "recap_metrics" })
    XCTAssertEqual(recap.payload["focus_session_count"], "2")
    XCTAssertEqual(recap.payload["focus_total_seconds"], "7200")
    XCTAssertEqual(recap.payload["ai_ratio_pct"], "40")
    XCTAssertEqual(recap.payload["peak_productivity_hour"], "15")
    XCTAssertEqual(recap.payload["files_touched_count"], "3")
    XCTAssertEqual(recap.payload["commit_count"], "2")

    let r = renderThroughBoundary(events)
    XCTAssertFalse(r.contains("secret-acquisition"), "file paths never reach the LLM (CR-2)")
    XCTAssertTrue(r.contains("files_touched_count=3"), "only the count survives the boundary")
  }

  // MARK: - 2. self-authored PR carved; commit excluded; raw title dropped.

  func testSelfAuthoredPRCarved_commitExcluded() throws {
    let db = try openWriter()
    try writeEvent(
      db, tsMs: 3_000,
      payload: [
        "event_kind": "gh_pr_opened", "title": "ALICE-REFACTOR-AUTH",
        "authored_by_viewer": "true", "additions": "12",
      ])
    // A self-authored commit exists but must NOT be emitted as a self-authored
    // event (CR-1) — only counted.
    try writeEvent(
      db, tsMs: 4_000,
      payload: [
        "event_kind": "gh_commit_pushed", "title": "BOB-MERGE-COMMIT",
        "authored_by_viewer": "true", "sha": "z",
      ])
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)

    XCTAssertTrue(
      events.contains { $0.kind == "gh_pr_opened" }, "self-authored PR is gathered as a real event")
    XCTAssertFalse(
      events.contains { $0.kind == "gh_commit_pushed" },
      "commit-pushed is NEVER emitted as a self-authored event (CR-1)")

    let r = renderThroughBoundary(events)
    XCTAssertTrue(r.contains("self_authored_title=ALICE-REFACTOR-AUTH"))
    XCTAssertFalse(r.contains("BOB-MERGE-COMMIT"), "others' commit subject never ships")
    let recap = try XCTUnwrap(events.first { $0.kind == "recap_metrics" })
    XCTAssertEqual(recap.payload["commit_count"], "1", "the commit is still counted")
  }

  // MARK: - 3. blocker_fact structured-only (excerpt never gathered).

  func testBlockerFactStructuredOnly() throws {
    let db = try openWriter()
    try db.writeSQL { rawDB in
      try rawDB.execute(
        sql: """
            INSERT INTO blockers (target_kind, target_ref, blocker_kind, blocker_excerpt, started_at_ms)
            VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          Schema.TargetKinds.linearIssue, "LEA-1", Schema.BlockerKinds.linearStuck,
          "SENTINEL-BLOCKER-EXCERPT", 1_000,
        ])
    }
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    let blocker = try XCTUnwrap(events.first { $0.kind == "blocker_fact" })
    XCTAssertEqual(blocker.payload["target_ref"], "LEA-1")
    XCTAssertNil(blocker.payload["blocker_excerpt"], "excerpt is never gathered (escalation-only)")
    XCTAssertFalse(renderThroughBoundary(events).contains("SENTINEL-BLOCKER-EXCERPT"))
  }

  // MARK: - 4. open_question_fact structured-only.

  func testOpenQuestionFactStructuredOnly() throws {
    let db = try openWriter()
    try db.writeSQL { rawDB in
      try rawDB.execute(
        sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (1000,'action','t','{}')")
      try rawDB.execute(
        sql: """
            INSERT INTO open_questions (event_id, question_excerpt, linear_issue_ref, opened_at_ms)
            VALUES (1, ?, ?, ?)
          """,
        arguments: ["SENTINEL-Q-EXCERPT", "LEA-88", 1_000])
    }
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    let q = try XCTUnwrap(events.first { $0.kind == "open_question_fact" })
    XCTAssertEqual(q.payload["linear_issue_ref"], "LEA-88")
    XCTAssertNil(q.payload["question_excerpt"])
    XCTAssertFalse(renderThroughBoundary(events).contains("SENTINEL-Q-EXCERPT"))
  }

  // MARK: - 5. where_stopped_fact: fresh → wip booleans; stale → omitted.

  func testWhereStoppedFreshStructuredOnly() throws {
    let db = try openWriter()
    try db.writeSQL { rawDB in
      try WhereStoppedLogStore.append(
        WhereStoppedOutput(
          excerpt: "SENTINEL-WHERE-EXCERPT",
          wipSignals: WipSignals(commitWip: true, ciFailing: false, midEdit: true),
          anchorEventID: nil),
        generatedAtMs: nowMs - 1_000, in: rawDB)
    }
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    let ws = try XCTUnwrap(events.first { $0.kind == "where_stopped_fact" })
    XCTAssertEqual(ws.payload["wip_commit"], "true")
    XCTAssertNil(ws.payload["excerpt"])
    XCTAssertFalse(renderThroughBoundary(events).contains("SENTINEL-WHERE-EXCERPT"))
  }

  func testWhereStoppedStaleExcluded() throws {
    let db = try openWriter()
    let oneDayMs: Int64 = 24 * 60 * 60 * 1000
    try db.writeSQL { rawDB in
      try WhereStoppedLogStore.append(
        WhereStoppedOutput(
          excerpt: "old", wipSignals: WipSignals(commitWip: false, ciFailing: false, midEdit: false),
          anchorEventID: nil),
        generatedAtMs: nowMs - oneDayMs - 1, in: rawDB)
    }
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    XCTAssertFalse(events.contains { $0.kind == "where_stopped_fact" })
  }

  // MARK: - 6. self-authored cap.

  func testSelfAuthoredCappedAt50() throws {
    let db = try openWriter()
    for i in 0..<60 {
      try writeEvent(
        db, tsMs: Int64(100 + i),
        payload: [
          "event_kind": "gh_pr_opened", "title": "PR-\(i)", "authored_by_viewer": "true",
        ])
    }
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    XCTAssertEqual(
      events.filter { $0.kind == "gh_pr_opened" }.count, WorkFactGatherer.selfAuthoredCap)
  }

  // MARK: - 7. bucket-1-safe by construction: no gathered event carries a bundleID.

  func testNoGatheredEventCarriesBundleID() throws {
    let db = try openWriter()
    try writeEvent(
      db, tsMs: 3_000,
      payload: ["event_kind": "gh_pr_opened", "title": "x", "authored_by_viewer": "true"])
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    XCTAssertTrue(
      events.allSatisfy { $0.bundleID == nil },
      "the gatherer emits no app-identity events → bucket-1 is moot by construction")
  }

  // MARK: - 8. non-viewer-authored PR is not gathered as self-authored.

  func testNonAuthoredPRNotGathered() throws {
    let db = try openWriter()
    try writeEvent(
      db, tsMs: 3_000,
      payload: ["event_kind": "gh_pr_opened", "title": "EVE-PR"])  // no authored_by_viewer
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    XCTAssertFalse(events.contains { $0.kind == "gh_pr_opened" })
    XCTAssertFalse(renderThroughBoundary(events).contains("EVE-PR"))
  }

  // MARK: - 9. cross_link_fact: linear_issue verbatim + github_pr NORMALIZED to
  //          #N (P3 — owner/repo stripped); github_user excluded; non-canonical
  //          github_pr dropped; from_ref resolves from safe keys, never branch/title.

  func testCrossLinkFact_linearAndNormalizedGithubPR_ownerRepoStripped() throws {
    let db = try openWriter()
    // id=1 — a PR I reviewed; number=57 → from_ref=57. Carries repo (must never ship).
    try writeEvent(
      db, tsMs: 5_000,
      payload: [
        "event_kind": "gh_pr_review_comment_authored", "number": "57", "repo": "acme/secret-repo",
      ])
    // id=2 — a slack thread referencing a PR URL (the github_pr / owner-repo link source).
    try writeEvent(db, tsMs: 6_000, payload: ["event_kind": "slack_thread_reply_aggregate"])
    // id=3 — a source with ONLY branch+title (no safe id key) → from_ref must be omitted.
    try writeEvent(
      db, tsMs: 7_000,
      payload: ["event_kind": "gh_commit_pushed", "branch": "feature/secret", "title": "SECRET-TITLE"])

    func insertLink(_ from: Int64, _ kind: String, _ tk: String, _ ref: String, _ ts: Int64) throws {
      try db.writeSQL { rawDB in
        try rawDB.execute(
          sql: """
            INSERT INTO event_links
              (from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)
            VALUES (?,?,?,?,?,?)
            """,
          arguments: [from, kind, tk, ref, 0.5, ts])
      }
    }
    // linear_issue link on id=1 → EMITTED (target_ref = LEAF-88).
    try insertLink(1, Schema.LinkKinds.linearIDInText, Schema.TargetKinds.linearIssue, "LEAF-88", 5_000)
    // reviewer_assigned (github_user, 3rd-party login) on id=1 → EXCLUDED (CR-2).
    try insertLink(1, Schema.LinkKinds.reviewerAssigned, Schema.TargetKinds.githubUser, "eve-login", 5_000)
    // non-canonical github_pr on id=1 (compare URL, not /pull/N) → fail-closed DROP (P3).
    try insertLink(
      1, Schema.LinkKinds.prURLInSlack, Schema.TargetKinds.githubPR, "acme/secret-repo/compare/x", 5_000)
    // pr_url_in_slack (github_pr → owner/repo/pull/42) on id=2 → P3: EMITTED, NORMALIZED to #42.
    try insertLink(
      2, Schema.LinkKinds.prURLInSlack, Schema.TargetKinds.githubPR, "acme/secret-repo/pull/42", 6_000)
    // branch_name_linear_ref (linear_issue) on id=3 → EMITTED, from_ref omitted (no safe key).
    try insertLink(
      3, Schema.LinkKinds.branchNameLinearRef, Schema.TargetKinds.linearIssue, "LEAF-99", 7_000)

    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    let links = events.filter { $0.kind == "cross_link_fact" }
    XCTAssertEqual(links.count, 3, "two linear_issue + one normalized github_pr (#42); github_user + non-canonical dropped")

    let toLEAF88 = try XCTUnwrap(links.first { $0.payload["target_ref"] == "LEAF-88" })
    XCTAssertEqual(toLEAF88.payload["from_kind"], "gh_pr_review_comment_authored")
    XCTAssertEqual(toLEAF88.payload["from_ref"], "57", "from_ref resolves from the safe `number` key")
    XCTAssertEqual(toLEAF88.payload["link_kind"], Schema.LinkKinds.linearIDInText)
    XCTAssertEqual(toLEAF88.payload["target_kind"], Schema.TargetKinds.linearIssue)
    XCTAssertNil(toLEAF88.payload["link_confidence"], "confidence (moat constant) is never emitted (CR-4)")

    let toLEAF99 = try XCTUnwrap(links.first { $0.payload["target_ref"] == "LEAF-99" })
    XCTAssertNil(
      toLEAF99.payload["from_ref"], "from_ref omitted when only branch/title present (CR-3)")

    // P3 — normalized github_pr link. The owner/repo slug is stripped to bare #42.
    let toPR = try XCTUnwrap(links.first { $0.payload["target_ref"] == "#42" })
    XCTAssertEqual(toPR.payload["target_kind"], Schema.TargetKinds.githubPR)
    XCTAssertEqual(toPR.payload["from_kind"], "slack_thread_reply_aggregate")
    XCTAssertNil(toPR.payload["from_ref"], "slack source carries no safe id key → from_ref omitted")

    XCTAssertTrue(links.allSatisfy { $0.bundleID == nil }, "bucket-1-safe by construction")

    let r = renderThroughBoundary(events)
    XCTAssertTrue(r.contains("target_ref=LEAF-88"))
    XCTAssertTrue(r.contains("target_ref=LEAF-99"))
    XCTAssertTrue(r.contains("target_ref=#42"), "github_pr normalized to bare #N (P3)")
    XCTAssertFalse(r.contains("owner/repo/pull/42"), "raw owner/repo/pull slug never ships")
    XCTAssertFalse(r.contains("acme/secret-repo"), "repo slug never enters the cross_link_fact (CR-2/value sentinel)")
    XCTAssertFalse(r.contains("/compare/"), "non-canonical github_pr ref is dropped fail-closed")
    XCTAssertFalse(r.contains("eve-login"), "github_user 3rd-party login excluded (CR-2)")
    XCTAssertFalse(r.contains("feature/secret"), "branch never the from_ref (CR-3)")
    XCTAssertFalse(r.contains("SECRET-TITLE"), "title never the from_ref (CR-3)")
  }

  // MARK: - 9b. gatherSelectedBodies (P3 escalation retrieval): carries bundleID
  //          from the column so makeEscalation's bucket-1 drop works (CR-5).

  func testGatherSelectedBodies_carriesBundleIDForBucket1Drop() throws {
    let db = try openWriter()
    // id=1 — a normal work comment with a body.
    try writeEvent(
      db, tsMs: 5_000,
      payload: ["event_kind": "gh_pr_review_comment_authored", "body": "WORK-BODY"])
    // id=2 — a personal-app event with a body (bundle_id on the COLUMN).
    try writeEvent(
      db, tsMs: 6_000, bundleID: "com.test.personal",
      payload: ["event_kind": "attention", "body": "PERSONAL-BODY"])
    // id=3 — a Slack DM (channel_name == "DM") with a body.
    try writeEvent(
      db, tsMs: 7_000,
      payload: ["event_kind": "slack_thread_reply_aggregate", "channel_name": "DM", "body": "DM-BODY"])

    let selected = try makeGatherer().gatherSelectedBodies(eventIDs: [1, 2, 3])
    XCTAssertEqual(selected.count, 3, "all named events are fetched")
    // The personal-app event must carry its bundleID FROM THE COLUMN (else the
    // boundary's bucket-1 drop fails open — CR-5).
    let personal = try XCTUnwrap(selected.first { $0.payload["body"] == "PERSONAL-BODY" })
    XCTAssertEqual(personal.bundleID, "com.test.personal")

    // End-to-end: makeEscalation drops the personal + DM bodies, keeps the work body.
    let escalated = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
      .makeEscalation(selected: selected)
    let flat = escalated.bodies.map(\.text).joined(separator: "|")
    XCTAssertTrue(flat.contains("WORK-BODY"))
    XCTAssertFalse(flat.contains("PERSONAL-BODY"), "personal-app body must not escalate (bundleID from column)")
    XCTAssertFalse(flat.contains("DM-BODY"), "Slack DM body must not escalate")
    XCTAssertEqual(escalated.bodies.count, 1)
  }

  func testGatherSelectedBodies_emptyAndMissingIDs() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 5_000, payload: ["event_kind": "gh_pr_opened", "body": "x"])
    XCTAssertTrue(try makeGatherer().gatherSelectedBodies(eventIDs: []).isEmpty)
    // Non-existent ids → silently absent.
    XCTAssertTrue(try makeGatherer().gatherSelectedBodies(eventIDs: [999]).isEmpty)
  }

  // MARK: - 10. trend_metrics + latency_metrics (P2 cluster 4) from the insights engine.

  private struct TrendFakeInsights: DerivedInsights {
    func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { [] }
    func focusSessions(period: DateInterval) throws -> [FocusSession] { [] }
    func contextSwitchRate(period: DateInterval) throws -> Double { 0 }
    func deepWorkStreak() throws -> DeepWorkStreak { DeepWorkStreak(days: 3, totalSeconds: 9000) }
    func peakProductivityHour() throws -> Int? { nil }
    func filesTouched(period: DateInterval) throws -> [String] { [] }
    func aiRatio(period: DateInterval) throws -> Double { 0 }
    func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown { .empty }
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { 0 }
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { 0 }
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { [] }
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot? { nil }
    func weekOverWeekDelta() throws -> Double? { -0.15 }
    func activeDaysInRow() throws -> Int { 5 }
    func weeklyMetrics(now: Date) throws -> WeeklyMetrics {
      WeeklyMetrics(
        dailySeries: Array(repeating: .empty, count: 7), peakHour: 15, wowDelta: -0.15,
        commitStreak: 4, issueCloseStreak: 2, huddleStreak: 1, focusSessionStreak: 3,
        heavyPulseStreak: 6)
    }
    func longestUninterruptedWindow(period: DateInterval) throws -> UninterruptedWindow? {
      UninterruptedWindow(
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 5400),
        durationSeconds: 5400, sourcesActiveInPeriod: ["slack"])
    }
    func linearTransitions(period: DateInterval) throws -> LinearTransitionBreakdown {
      LinearTransitionBreakdown(started: 3, completed: 2, canceled: 1, reopened: 0)
    }
    func linearCompletionRate(period: DateInterval) throws -> Double? { 0.8 }
    func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown {
      GitHubActivityBreakdown(
        eventsCount: 0, byRepo: [], byEventKind: [],
        prCycleStats: LatencyStats(
          medianSeconds: 3600, avgSeconds: 4000, maxSeconds: 86400, sampleCount: 7),
        reviewDelayStats: nil)  // nil → its keys must be omitted
    }
    func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown {
      LinearActivityBreakdown(
        issuesTouched: 0, byProject: [], byStatus: [],
        completionDurationStats: LatencyStats(
          medianSeconds: 7200, avgSeconds: 8000, maxSeconds: 100_000, sampleCount: 4))
    }
    func slackActivity(period: DateInterval) throws -> SlackActivityBreakdown {
      SlackActivityBreakdown(
        messagesCount: 0, huddleMinutes: 0, byChannel: [],
        huddleSessionStats: LatencyStats(
          medianSeconds: 1800, avgSeconds: 1900, maxSeconds: 3600, sampleCount: 2))
    }
  }

  func testTrendMetrics_magnitudes_noSourceNames() throws {
    _ = try openWriter()
    let events = try makeGatherer(insights: TrendFakeInsights()).gather(period: period, nowMs: nowMs)
    let trend = try XCTUnwrap(events.first { $0.kind == "trend_metrics" })
    XCTAssertEqual(trend.payload["wow_delta_pct"], "-15", "fractional delta quantized to signed pct")
    XCTAssertEqual(trend.payload["commit_streak"], "4")
    XCTAssertEqual(trend.payload["heavy_pulse_streak"], "6")
    XCTAssertEqual(trend.payload["deep_work_streak_days"], "3")
    XCTAssertEqual(trend.payload["deep_work_streak_seconds"], "9000")
    XCTAssertEqual(trend.payload["active_days_in_row"], "5")
    XCTAssertEqual(trend.payload["linear_completion_rate_pct"], "80")
    XCTAssertEqual(trend.payload["uninterrupted_window_seconds"], "5400")
    XCTAssertEqual(trend.payload["uninterrupted_window_sources_count"], "1")
    XCTAssertEqual(trend.payload["linear_started_count"], "3")
    XCTAssertEqual(trend.payload["linear_completed_count"], "2")
    XCTAssertEqual(trend.payload["linear_canceled_count"], "1")
    XCTAssertEqual(trend.payload["linear_reopened_count"], "0")
    XCTAssertNil(trend.bundleID)
    XCTAssertFalse(
      trend.payload.values.contains("slack"), "source NAMES are never gathered — only the count (CR-5)")
  }

  func testLatencyMetrics_nilStatsOmitted() throws {
    _ = try openWriter()
    let events = try makeGatherer(insights: TrendFakeInsights()).gather(period: period, nowMs: nowMs)
    let lat = try XCTUnwrap(events.first { $0.kind == "latency_metrics" })
    XCTAssertEqual(lat.payload["pr_cycle_median_sec"], "3600")
    XCTAssertEqual(lat.payload["pr_cycle_max_sec"], "86400")
    XCTAssertEqual(lat.payload["pr_cycle_sample_count"], "7")
    XCTAssertEqual(lat.payload["linear_completion_median_sec"], "7200")
    XCTAssertEqual(lat.payload["huddle_session_median_sec"], "1800")
    XCTAssertNil(lat.payload["review_delay_median_sec"], "nil LatencyStats → keys omitted (CR-8)")
    XCTAssertNil(lat.bundleID)
  }

  func testLatencyMetricsOmittedWhenNoSamples_trendStillEmitted() throws {
    _ = try openWriter()  // default FakeInsights → all .empty / nil → no latency samples
    let events = try makeGatherer().gather(period: period, nowMs: nowMs)
    XCTAssertFalse(
      events.contains { $0.kind == "latency_metrics" }, "no latency event when every stat is nil (CR-8)")
    let trend = try XCTUnwrap(events.first { $0.kind == "trend_metrics" }, "trend_metrics always emitted")
    XCTAssertEqual(trend.payload["commit_streak"], "0", "default streaks are 0, not a crash (tiny/empty period)")
    XCTAssertNil(trend.payload["wow_delta_pct"], "nil WoW → omitted")
  }

  // MARK: - gatherSelectedBodiesKeyed (AI-UI-2)

  func testKeyed_returnsIDsPairedWithEvents() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 1_000, payload: ["event_kind": "gh_pr_comment", "body": "alpha"])
    try writeEvent(db, tsMs: 2_000, payload: ["event_kind": "gh_pr_comment", "body": "beta"])
    let ids = try allEventIDs()
    let keyed = try makeGatherer().gatherSelectedBodiesKeyed(eventIDs: ids)
    XCTAssertEqual(keyed.count, 2)
    XCTAssertEqual(Set(keyed.map(\.id)), Set(ids))
    XCTAssertEqual(keyed.compactMap { $0.event.payload["body"] }.sorted(), ["alpha", "beta"])
  }

  func testKeyed_unkeyedDelegatesBitForBit() throws {
    let db = try openWriter()
    try writeEvent(
      db, tsMs: 1_000, bundleID: "com.example.app",
      payload: ["event_kind": "gh_pr_comment", "body": "alpha"])
    let ids = try allEventIDs()
    let old = try makeGatherer().gatherSelectedBodies(eventIDs: ids)
    let new = try makeGatherer().gatherSelectedBodiesKeyed(eventIDs: ids).map(\.event)
    XCTAssertEqual(old, new)
  }

  private func allEventIDs() throws -> [Int64] {
    let db = try LeafCore.Database.openForRead(
      at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    return try db.readSQL { rawDB in
      try Int64.fetchAll(rawDB, sql: "SELECT id FROM events ORDER BY id")
    }
  }
}
