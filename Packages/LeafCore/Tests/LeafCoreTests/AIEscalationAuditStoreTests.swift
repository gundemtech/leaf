import XCTest
import GRDB
@testable import LeafCore

/// Phase AI Coworker P3 — append-only audit store round-trip + invariants (M031).
final class AIEscalationAuditStoreTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ai-audit-\(UUID().uuidString).sqlite")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testAppendThenRecentRoundTripsNewestFirst() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try db.appendAIEscalationAudit(
      generatedAtMs: 1000, questionExcerpt: "summarize PR", model: "haiku",
      eventIDs: [11, 22], sourceSummary: "2 events: 2 gh_pr_review_comment_authored")
    try db.appendAIEscalationAudit(
      generatedAtMs: 2000, questionExcerpt: nil, model: "sonnet",
      eventIDs: [33], sourceSummary: "1 events: 1 gh_issue_comment_authored")

    let rows = try db.recentAIEscalationAudit(limit: 10)
    XCTAssertEqual(rows.count, 2)
    // Newest first.
    XCTAssertEqual(rows[0].generatedAtMs, 2000)
    XCTAssertEqual(rows[0].model, "sonnet")
    XCTAssertNil(rows[0].questionExcerpt)
    XCTAssertEqual(rows[0].eventIDs, [33])
    XCTAssertEqual(rows[1].generatedAtMs, 1000)
    XCTAssertEqual(rows[1].eventIDs, [11, 22])
    XCTAssertEqual(rows[1].questionExcerpt, "summarize PR")
    XCTAssertEqual(rows[1].sourceSummary, "2 events: 2 gh_pr_review_comment_authored")
  }

  func testLimitZeroReturnsEmpty() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try db.appendAIEscalationAudit(
      generatedAtMs: 1, questionExcerpt: nil, model: "haiku", eventIDs: [1], sourceSummary: "x")
    XCTAssertEqual(try db.recentAIEscalationAudit(limit: 0).count, 0)
  }

  func testWriterModeGuard_readerThrows() throws {
    // Writer creates + migrates the DB; a read-only handle must refuse to append.
    _ = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    let reader = try Database.openForRead(at: tempURL, config: .weakDefaults, encryption: nil)
    XCTAssertThrowsError(
      try reader.appendAIEscalationAudit(
        generatedAtMs: 1, questionExcerpt: nil, model: "haiku", eventIDs: [1], sourceSummary: "x"))
  }

  func testTwoWriteHandlesBothAppend() throws {
    // Cross-writer sanity (M-9): a second openForWrite over the same file also
    // appends — MCPServer opens a brief writer alongside the Agent (WAL + locks).
    let a = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try a.appendAIEscalationAudit(
      generatedAtMs: 1, questionExcerpt: nil, model: "haiku", eventIDs: [1], sourceSummary: "a")
    let b = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    try b.appendAIEscalationAudit(
      generatedAtMs: 2, questionExcerpt: nil, model: "haiku", eventIDs: [2], sourceSummary: "b")
    XCTAssertEqual(try b.recentAIEscalationAudit(limit: 10).count, 2)
  }
}
