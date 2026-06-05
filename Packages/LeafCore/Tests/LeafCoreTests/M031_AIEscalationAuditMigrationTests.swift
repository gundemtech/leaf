import XCTest
import GRDB
@testable import LeafCore

/// Phase AI Coworker P3 — fresh-DB migration check for `ai_escalation_audit`
/// (M031): the append-only reverse audit of cloud escalations (§8 п.4). Asserts
/// the table, its columns, and the `generated_at_ms` read-back index exist.
final class M031_AIEscalationAuditMigrationTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("m031-\(UUID().uuidString).sqlite")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testFreshDB_AIEscalationAuditPresent() throws {
    let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)

    XCTAssertTrue(try db.tableExists("ai_escalation_audit"))

    let cols = try db.fetchTableColumns("ai_escalation_audit")
    for c in ["id", "generated_at_ms", "question_excerpt", "model", "event_ids_json", "source_summary"] {
      XCTAssertTrue(cols.contains(c), "missing column \(c)")
    }

    XCTAssertTrue(
      try db.fetchTableIndexes("ai_escalation_audit").contains("idx_ai_escalation_audit_generated_at"))
  }
}
