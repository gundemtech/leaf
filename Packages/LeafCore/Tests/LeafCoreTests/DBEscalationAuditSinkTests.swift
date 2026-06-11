// AI-UI-2 — DBEscalationAuditSink promoted из LeafMCP в LeafCore: app
// (EscalationReader) и MCP (EscalateToAITool) используют один sink.

import XCTest

@testable import LeafCore

final class DBEscalationAuditSinkTests: XCTestCase {
  func testRecord_appendsAuditRow() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-sink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let dbURL = tempDir.appendingPathComponent("events.sqlite")
    _ = try LeafCore.Database.openForWrite(
      at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

    let sink = DBEscalationAuditSink(
      dbURL: dbURL, dbConfig: .weakDefaults, dbEncryption: .deterministicTest)
    try await sink.record(
      EscalationAuditEntry(
        occurredAtMs: 42, eventIDs: [1, 2], escalatedBodyCount: 2, droppedCount: 0,
        question: "q", model: "haiku", path: "byok", sourceSummary: "s"))

    let db = try LeafCore.Database.openForRead(
      at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    let rows = try db.recentAIEscalationAudit(limit: 10)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.eventIDs, [1, 2])
    XCTAssertEqual(rows.first?.generatedAtMs, 42)
  }
}
