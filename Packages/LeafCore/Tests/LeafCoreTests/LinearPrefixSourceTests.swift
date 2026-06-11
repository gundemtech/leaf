// Use-case rebuild Track A0 — Linear prefix discovery from observed payloads.
//
// LinearIDExtractor requires a prefix whitelist; before A0 nothing supplied it
// in production. The source derives prefixes from `issue_key` /
// `linked_linear_id` payload values already captured in `events`, with a TTL
// cache so collectors can call it on every write without re-querying.

import XCTest
import GRDB
@testable import LeafCore

final class LinearPrefixSourceTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-prefix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeDB() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func seed(_ db: LeafCore.Database, payloadKey: String, value: String) throws {
    try db.write(RawEvent(signalType: .action, payload: ["event_kind": "issue_updated", payloadKey: value]))
  }

  func testPrefixes_DerivedFromIssueKeyAndLinkedLinearID() throws {
    let db = try makeDB()
    try seed(db, payloadKey: "issue_key", value: "GUN-12")
    try seed(db, payloadKey: "issue_key", value: "GUN-31")
    try seed(db, payloadKey: "linked_linear_id", value: "LEA-431")

    let source = LinearPrefixSource(database: db, ttlSeconds: 600, now: { Date(timeIntervalSince1970: 0) })
    XCTAssertEqual(source.prefixes(), ["GUN", "LEA"])
  }

  func testPrefixes_RejectsMalformedValues() throws {
    let db = try makeDB()
    try seed(db, payloadKey: "issue_key", value: "nodash")
    try seed(db, payloadKey: "issue_key", value: "abc-12")        // lowercase
    try seed(db, payloadKey: "issue_key", value: "TOOLONGG-1")    // prefix > 5 chars
    try seed(db, payloadKey: "issue_key", value: "A-")            // no number
    try seed(db, payloadKey: "issue_key", value: "GUN-7")

    let source = LinearPrefixSource(database: db, ttlSeconds: 600, now: { Date(timeIntervalSince1970: 0) })
    XCTAssertEqual(source.prefixes(), ["GUN"])
  }

  func testPrefixes_TTLCache_RefreshesAfterExpiry() throws {
    let db = try makeDB()
    try seed(db, payloadKey: "issue_key", value: "GUN-1")

    nonisolated(unsafe) var nowSec: TimeInterval = 0
    let source = LinearPrefixSource(database: db, ttlSeconds: 600, now: { Date(timeIntervalSince1970: nowSec) })
    XCTAssertEqual(source.prefixes(), ["GUN"])

    try seed(db, payloadKey: "issue_key", value: "LEA-2")
    // Inside TTL — cached result, new prefix not visible yet.
    nowSec = 300
    XCTAssertEqual(source.prefixes(), ["GUN"])
    // Past TTL — refreshed.
    nowSec = 601
    XCTAssertEqual(source.prefixes(), ["GUN", "LEA"])
  }

  func testPrefixes_EmptyDatabase_ReturnsEmpty() throws {
    let db = try makeDB()
    let source = LinearPrefixSource(database: db, ttlSeconds: 600, now: { Date(timeIntervalSince1970: 0) })
    XCTAssertEqual(source.prefixes(), [])
  }
}
