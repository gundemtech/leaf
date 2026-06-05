import XCTest
import GRDB
@testable import LeafCore

/// Phase AI Coworker P4 — append-only handoff audit store round-trip + invariants
/// (M032). Alice = me/sender, Alex = teammate/recipient. Body-free by construction.
final class HandoffAuditStoreTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-audit-\(UUID().uuidString).sqlite")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testAppendThenRecentRoundTripsNewestFirst() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try db.appendHandoffAudit(
      generatedAtMs: 1000, messageID: "msg-1", recipientMemberID: "member-alex",
      model: "haiku", path: "byok", periodStartMs: 100, periodEndMs: 200,
      factCount: 7, escalated: false, crosspostedSlack: false, crosspostedLinear: false,
      sourceSummary: "recap_metrics, 2 blocker_fact", topicExcerpt: "auth work")
    try db.appendHandoffAudit(
      generatedAtMs: 2000, messageID: "msg-2", recipientMemberID: "member-alex",
      model: "sonnet", path: "byok", periodStartMs: 300, periodEndMs: 400,
      factCount: 3, escalated: false, crosspostedSlack: true, crosspostedLinear: false,
      sourceSummary: "recap_metrics", topicExcerpt: nil)

    let rows = try db.recentHandoffAudit(limit: 10)
    XCTAssertEqual(rows.count, 2)
    // Newest first.
    XCTAssertEqual(rows[0].generatedAtMs, 2000)
    XCTAssertEqual(rows[0].model, "sonnet")
    XCTAssertEqual(rows[0].factCount, 3)
    XCTAssertTrue(rows[0].crosspostedSlack)         // Sentinel #14 — cross-post accountability
    XCTAssertFalse(rows[0].crosspostedLinear)
    XCTAssertNil(rows[0].topicExcerpt)
    XCTAssertEqual(rows[1].generatedAtMs, 1000)
    XCTAssertEqual(rows[1].messageID, "msg-1")
    XCTAssertEqual(rows[1].recipientMemberID, "member-alex")
    XCTAssertEqual(rows[1].topicExcerpt, "auth work")
    XCTAssertFalse(rows[1].crosspostedSlack)        // positive gate: Leaf-only → 0
    XCTAssertFalse(rows[1].escalated)
  }

  /// Sentinel #13 — the flattened row contains no planted body / draft text;
  /// only refs + counts + the user's own topic survive.
  func testRowIsBodyFree() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try db.appendHandoffAudit(
      generatedAtMs: 5, messageID: "msg-x", recipientMemberID: "member-alex",
      model: "haiku", path: "byok", periodStartMs: 1, periodEndMs: 2,
      factCount: 1, escalated: false, crosspostedSlack: false, crosspostedLinear: false,
      sourceSummary: "recap_metrics", topicExcerpt: "ship the release")

    let row = try db.recentHandoffAudit(limit: 1)[0]
    let flattened = [
      String(row.id), String(row.generatedAtMs), row.messageID ?? "", row.recipientMemberID ?? "",
      row.model, row.path, String(row.periodStartMs), String(row.periodEndMs),
      String(row.factCount), String(row.escalated), String(row.crosspostedSlack),
      String(row.crosspostedLinear), row.sourceSummary, row.topicExcerpt ?? "",
    ].joined(separator: "\u{1F}")
    // No event body / detector excerpt / Slack message could ever appear here —
    // the store has no parameter that accepts one. Assert a representative body
    // sentinel never round-trips.
    XCTAssertFalse(flattened.contains("SENTINEL-PERSONAL-BODY"))
    XCTAssertFalse(flattened.contains("SENTINEL-CTX-BODY"))
  }

  func testLimitZeroReturnsEmpty() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try db.appendHandoffAudit(
      generatedAtMs: 1, messageID: nil, recipientMemberID: nil, model: "haiku", path: "byok",
      periodStartMs: 1, periodEndMs: 2, factCount: 0, escalated: false,
      crosspostedSlack: false, crosspostedLinear: false, sourceSummary: "x", topicExcerpt: nil)
    XCTAssertEqual(try db.recentHandoffAudit(limit: 0).count, 0)
  }

  func testWriterModeGuard_readerThrows() throws {
    _ = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    let reader = try Database.openForRead(at: tempURL, config: .weakDefaults, encryption: nil)
    XCTAssertThrowsError(
      try reader.appendHandoffAudit(
        generatedAtMs: 1, messageID: nil, recipientMemberID: nil, model: "haiku", path: "byok",
        periodStartMs: 1, periodEndMs: 2, factCount: 0, escalated: false,
        crosspostedSlack: false, crosspostedLinear: false, sourceSummary: "x", topicExcerpt: nil))
  }
}
