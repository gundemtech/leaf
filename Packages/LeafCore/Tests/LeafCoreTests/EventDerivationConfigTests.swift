// Use-case rebuild Track A0 — instance-level derivation config on Database.
//
// Production root cause (2026-06-11 live diagnosis): every write entry point
// defaulted to empty Linear prefixes + substrate no-op derivers and no caller
// ever passed anything else, so event_links stayed empty forever. The config
// lets the Agent wire prefixes/derivers ONCE; collectors keep calling the
// write APIs with defaults.

import XCTest
import GRDB
@testable import LeafCore

final class EventDerivationConfigTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-derivcfg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeDB() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func configure(_ db: LeafCore.Database, prefixes: Set<String>) {
    db.configureDerivation(
      EventDerivationConfig(derivers: .publicSubstrate, linearPrefixes: { prefixes })
    )
  }

  private func bodyEvent(_ body: String, kind: String = "issue_updated") -> RawEvent {
    RawEvent(
      signalType: .action,
      payload: ["event_kind": kind, Schema.EventPayloadKeys.body: body]
    )
  }

  private func allLinks(_ db: LeafCore.Database) throws -> [EventLink] {
    try db.readSQL { rawDB in
      let ids = try Int64.fetchAll(rawDB, sql: "SELECT id FROM events")
      return try ids.flatMap { try EventLinksStore.linksFrom(eventID: $0, in: rawDB) }
    }
  }

  private func ftsMetaCount(_ db: LeafCore.Database) throws -> Int {
    try db.readSQL { rawDB in
      try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM events_fts_meta") ?? 0
    }
  }

  // MARK: - write(_:) family resolves config when caller passes defaults

  func testConfiguredDerivation_AppliesToPlainWrite() throws {
    let db = try makeDB()
    configure(db, prefixes: ["LEAF"])

    try db.write(bodyEvent("Working on LEAF-127 today"))

    let links = try allLinks(db)
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links[0].targetRef, "LEAF-127")
  }

  func testUnconfiguredDatabase_KeepsPriorBehavior() throws {
    let db = try makeDB()
    try db.write(bodyEvent("Working on LEAF-127 today"))
    XCTAssertTrue(try allLinks(db).isEmpty)
  }

  func testExplicitParams_OverrideConfig() throws {
    let db = try makeDB()
    configure(db, prefixes: ["LEAF"])

    // Caller explicitly opts out (empty prefix set) → config must NOT apply.
    try db.write(bodyEvent("Working on LEAF-127 today"), knownLinearPrefixes: [])

    XCTAssertTrue(try allLinks(db).isEmpty)
  }

  func testConfiguredDerivation_AppliesToBatchWriteAndPresencePath() throws {
    let db = try makeDB()
    configure(db, prefixes: ["GUN"])

    let offset = CollectorOffset(
      collectorID: "t", sourceID: "s", byteOffset: 0, inode: nil,
      size: 0, lastModifiedMs: 1, updatedMs: 1
    )
    try db.writeEventsOffsetAndPresence(
      [bodyEvent("Fixes GUN-52 reconnect")],
      offset: offset,
      presence: nil,
      nowMs: 1_000
    )

    let links = try allLinks(db)
    XCTAssertEqual(links.map(\.targetRef), ["GUN-52"])
  }

  // MARK: - writeEventsAndOffset regression (FTS/link bypass)

  func testWriteEventsAndOffset_IndexesFTSAndDerivesLinks() throws {
    let db = try makeDB()
    configure(db, prefixes: ["LEAF"])

    let offset = CollectorOffset(
      collectorID: "claude_code", sourceID: "x.jsonl", byteOffset: 10, inode: nil,
      size: 10, lastModifiedMs: 1, updatedMs: 1
    )
    // Body-bearing commit event through the ClaudeCodeCollector primary API.
    let event = RawEvent(
      signalType: .action,
      payload: [
        "event_kind": "gh_commit_pushed",
        Schema.EventPayloadKeys.body: "feat: LEAF-9 wire relay",
      ]
    )
    try db.writeEventsAndOffset([event], offset: offset)

    XCTAssertEqual(try ftsMetaCount(db), 1, "writeEventsAndOffset must index bodies into FTS")
    XCTAssertEqual(try allLinks(db).map(\.targetRef), ["LEAF-9"])
  }
}
