// Use-case rebuild Track A4 — shared feed-worthiness taxonomy.
//
// Live diagnosis: the unfiltered activity feed was dominated by
// claude_tokens_used spam, provider state pulses and bare attention pings —
// substance (commits, PRs, issues, decisions carriers) drowned. One shared
// classifier so every surface (QueryEngine feed, Search, composers) excludes
// the same noise. Fence: substance kinds must NEVER classify as noise.

import XCTest
import GRDB
@testable import LeafCore

final class EventKindTaxonomyTests: XCTestCase {

  func testDiagnosticKinds() {
    XCTAssertEqual(EventKindTaxonomy.feedClass(eventKind: "claude_tokens_used", signalType: "aiCollaboration"), .diagnostic)
  }

  func testStatePulseKinds() {
    for kind in [
      "gh_notifications_pulse", "linear_assigned_workload_pulse",
      "gh_pr_awaiting_review_count", "gh_my_open_pr_count",
      "clipboard_event_count", "gh_check_runs_status",
      "gh_pr_titles_backfill", "space_switched", "system_woke",
      "system_slept", "system_locked", "system_unlocked",
      "audio_route_changed",
    ] {
      XCTAssertEqual(
        EventKindTaxonomy.feedClass(eventKind: kind, signalType: "context"),
        .statePulse, "expected statePulse for \(kind)")
    }
  }

  func testBareAttentionPings_AreStatePulse() {
    XCTAssertEqual(EventKindTaxonomy.feedClass(eventKind: nil, signalType: "attention"), .statePulse)
    XCTAssertEqual(EventKindTaxonomy.feedClass(eventKind: "", signalType: "attention"), .statePulse)
  }

  func testSubstanceKinds_NeverClassifyAsNoise() {
    for kind in [
      "git_commit_authored", "gh_commit_pushed", "gh_pr_opened", "gh_pr_merged",
      "issue_updated", "status_transition", "linear_comment_authored",
      "slack_message_authored_aggregate", "slack_thread_reply_aggregate",
      "claude_prompt_submitted", "claude_session_ended",
      "vscode_active_doc_changed", "download_added",
    ] {
      XCTAssertEqual(
        EventKindTaxonomy.feedClass(eventKind: kind, signalType: "action"),
        .substance, "substance kind \(kind) must never be filtered as noise")
    }
  }

  func testUnknownKind_DefaultsToSubstance() {
    XCTAssertEqual(EventKindTaxonomy.feedClass(eventKind: "future_unknown_kind", signalType: "action"), .substance)
  }

  // MARK: - SQL predicate parity

  func testSQLPredicate_MatchesSwiftClassification() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-taxonomy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults, encryption: .deterministicTest)

    // substance
    try db.write(RawEvent(signalType: .action, payload: ["event_kind": "gh_pr_merged"]))
    try db.write(RawEvent(signalType: .action, payload: ["event_kind": "git_commit_authored", "body": "x"]))
    // noise
    try db.write(RawEvent(signalType: .context, payload: ["event_kind": "gh_notifications_pulse"]))
    try db.write(RawEvent(signalType: .context, payload: ["event_kind": "gh_my_open_pr_count"]))
    try db.write(RawEvent(signalType: .aiCollaboration, bundleID: "c", payload: ["event_kind": "claude_tokens_used"]))
    try db.write(RawEvent(signalType: .attention, bundleID: "ru.keepcoder.Telegram"))

    let ids = try db.readSQL { rawDB in
      try Int64.fetchAll(rawDB, sql: """
        SELECT id FROM events WHERE \(EventKindTaxonomy.substanceSQLPredicate())
        ORDER BY id ASC
        """)
    }
    XCTAssertEqual(ids.count, 2, "SQL predicate must keep exactly the substance rows")
  }
}
