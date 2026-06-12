// Use-case rebuild Track B2 — leaf_search composite + getDecision top-N +
// DecisionContext enrichment.

import XCTest
import GRDB
@testable import LeafCore

final class QueryEngineSearchAndTopNTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-b2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func openWriter() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func makeEngine() -> QueryEngine {
    QueryEngine(dbURL: dbURL, dbConfig: .weakDefaults,
                dbEncryption: .deterministicTest, detectorMoat: .publicSubstrate)
  }

  /// Body-bearing event + a manually pinned decision row (the detector moat
  /// is substrate no-op in tests).
  @discardableResult
  private func seedDecision(
    _ db: LeafCore.Database, tsMs: Int64, body: String, confidence: Double,
    payloadExtra: [String: String] = [:]
  ) throws -> Int64 {
    var payload = ["event_kind": "gh_commit_pushed", Schema.EventPayloadKeys.body: body]
    payload.merge(payloadExtra) { _, new in new }
    try db.write(RawEvent(
      timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
      signalType: .action, payload: payload))
    return try db.writeSQL { rawDB in
      let eventID = try Int64.fetchOne(rawDB, sql: "SELECT MAX(id) FROM events")!
      try rawDB.execute(sql: """
        INSERT INTO decisions (event_id, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms)
        VALUES (?, '[]', ?, ?, ?)
        """, arguments: [eventID, body, confidence, tsMs])
      return eventID
    }
  }

  func testGetDecision_TopN_OrderedByConfidence_BackCompatFirst() throws {
    let db = try openWriter()
    try seedDecision(db, tsMs: 1_000, body: "decide: use sqlite for storage", confidence: 0.7)
    try seedDecision(db, tsMs: 2_000, body: "decide: sqlite WAL is mandatory", confidence: 0.95)
    try seedDecision(db, tsMs: 3_000, body: "decide: sqlite pragma tuning", confidence: 0.8)

    let r = try makeEngine().getDecision(topic: "sqlite", period: nil, limit: 3)
    XCTAssertEqual(r.decisions.count, 3)
    XCTAssertEqual(r.decisions.map(\.decision.confidence), [0.95, 0.8, 0.7])
    XCTAssertEqual(r.decision?.decision.confidence, 0.95, "decision == decisions.first")
  }

  func testGetDecision_ContextCarriesShaAndOriginTs() throws {
    let db = try openWriter()
    try seedDecision(
      db, tsMs: 5_000, body: "decide: rotate tokens", confidence: 0.9,
      payloadExtra: ["sha": "a3f2c1d9deadbeef"])

    let r = try makeEngine().getDecision(topic: "rotate", period: nil)
    XCTAssertEqual(r.decision?.context?.commitShaShort, "a3f2c1d")
    XCTAssertEqual(r.decision?.context?.decidedAtMs, 5_000)
  }

  func testSearch_CompositeRanksDecisionFirst_AndClampsLimit() throws {
    let db = try openWriter()
    try seedDecision(db, tsMs: 1_000, body: "decide: queue over direct call", confidence: 0.9)
    for i in 0..<5 {
      try db.write(RawEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(2 + i)),
        signalType: .action,
        payload: ["event_kind": "gh_pr_opened", "repo": "a/b", "number": String(100 + i),
                  Schema.EventPayloadKeys.body: "queue work item \(i)"]))
    }

    let r = try makeEngine().search(
      query: "queue", period: PeriodSpec(startMs: 0, endMs: 100_000), limit: 3)
    XCTAssertEqual(r.results.count, 3, "limit must clamp rows")
    XCTAssertEqual(r.results.first?.kind, .decision)
    XCTAssertEqual(r.topMatchID, r.results.first?.id)
    XCTAssertEqual(r.totalCount, 6)
  }

  func testSearch_HyphenatedQuery_DoesNotThrow() throws {
    let db = try openWriter()
    try db.write(RawEvent(signalType: .action, payload: [
      "event_kind": "gh_commit_pushed", Schema.EventPayloadKeys.body: "fix point-fetch path",
    ]))
    XCTAssertNoThrow(
      try makeEngine().search(query: "point-fetch", period: PeriodSpec(startMs: 0, endMs: Int64.max)))
  }
}
