import XCTest
import GRDB
@testable import LeafCore

/// Phase AI Coworker P4 — fresh-DB migration check for `handoff_audit` (M032):
/// the append-only reverse audit of AI-assisted team handoffs (§8 п.4). Asserts
/// the table, its columns, and the `generated_at_ms` read-back index exist, and
/// that no body-bearing column is present (recipient is `member_id`, not pubkey).
final class M032_HandoffAuditMigrationTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("m032-\(UUID().uuidString).sqlite")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testFreshDB_HandoffAuditPresent() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)

    XCTAssertTrue(try db.tableExists("handoff_audit"))

    let cols = try db.fetchTableColumns("handoff_audit")
    for c in [
      "id", "generated_at_ms", "message_id", "recipient_member_id", "model", "path",
      "period_start_ms", "period_end_ms", "fact_count", "escalated",
      "crossposted_slack", "crossposted_linear", "source_summary", "topic_excerpt",
    ] {
      XCTAssertTrue(cols.contains(c), "missing column \(c)")
    }

    XCTAssertTrue(
      try db.fetchTableIndexes("handoff_audit").contains("idx_handoff_audit_generated_at"))
  }

  /// Sentinel #11 — the schema is structurally body-free: there is no column
  /// that could hold a message/comment body, and the recipient is identified by
  /// an opaque member id, never a pubkey.
  func testSchemaHasNoBodyBearingOrPubkeyColumn() throws {
    _ = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
    let reader = try Database.openForRead(at: tempURL, config: .weakDefaults, encryption: nil)
    let cols = try reader.fetchTableColumns("handoff_audit")
    for forbidden in ["body", "text", "content", "preview", "recipient_pubkey", "pubkey", "draft"] {
      XCTAssertFalse(cols.contains(forbidden), "handoff_audit must not have a \(forbidden) column")
    }
  }
}
