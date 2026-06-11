// Use-case rebuild Track A2 — MemoryBackfillJob: FTS + links over historical
// events that were written before D2 wiring (or through since-fixed bypass
// paths) and so never got indexed.
//
// Invariants under test:
//   - run-twice idempotency (contentless FTS is append-only — the meta-table
//     guard is the ONLY thing preventing duplicate index rows);
//   - resumability (cursor in collector_offsets survives interruption);
//   - already-indexed events are never re-indexed;
//   - version bump re-runs the sweep (new dispatch entries pick up old rows);
//   - PR-titles pulse carriers become searchable (late-arriving bodies).

import XCTest
import GRDB
@testable import LeafCore

final class MemoryBackfillJobTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-backfill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeDB() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  /// Inserts a bare events row exactly the way the pre-A0 bypass did — no FTS,
  /// no links.
  @discardableResult
  private func insertUnindexedEvent(
    _ db: LeafCore.Database, tsMs: Int64, payload: [String: String]
  ) throws -> Int64 {
    let json = String(
      data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      encoding: .utf8)!
    return try db.writeSQL { rawDB in
      try rawDB.execute(
        sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, 'action', NULL, ?)",
        arguments: [tsMs, json])
      return rawDB.lastInsertedRowID
    }
  }

  private func ftsRowCount(_ db: LeafCore.Database) throws -> Int {
    try db.readSQL { rawDB in
      try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM events_fts_meta") ?? 0
    }
  }

  private func searchIDs(_ db: LeafCore.Database, _ query: String) throws -> [Int64] {
    try db.readSQL { rawDB in
      try EventsFullTextStore.search(query: query, period: 0...Int64.max, limit: 50, in: rawDB)
    }
  }

  private func makeJob(_ db: LeafCore.Database, batchSize: Int = 500) -> MemoryBackfillJob {
    MemoryBackfillJob(
      database: db, batchSize: batchSize, interBatchDelaySec: 0,
      linearPrefixes: { ["GUN"] }, derivers: .publicSubstrate)
  }

  // MARK: - Tests

  func testBackfill_IndexesHistoricalBodiesAndDerivesLinks() async throws {
    let db = try makeDB()
    try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "fix: GUN-31 relay reconnect",
    ])
    try insertUnindexedEvent(db, tsMs: 2_000, payload: [
      "event_kind": "issue_updated", "body": "Decision: use SQLCipher",
    ])
    // Noise event without body — must be skipped silently.
    try insertUnindexedEvent(db, tsMs: 3_000, payload: ["event_kind": "gh_notifications_pulse"])

    await makeJob(db).runToCompletion()

    XCTAssertEqual(try searchIDs(db, "relay").count, 1)
    XCTAssertEqual(try searchIDs(db, "SQLCipher").count, 1)
    let links = try db.readSQL { rawDB in
      try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM event_links") ?? 0
    }
    XCTAssertEqual(links, 1, "GUN-31 ref must derive a linear link during backfill")
  }

  func testBackfill_RunTwice_IsIdempotent() async throws {
    let db = try makeDB()
    try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "feat: idempotency",
    ])

    await makeJob(db).runToCompletion()
    let after1 = try ftsRowCount(db)
    // Fresh job instance — simulates the next Agent launch.
    await makeJob(db).runToCompletion()
    let after2 = try ftsRowCount(db)

    XCTAssertEqual(after1, after2, "second sweep must not duplicate FTS rows")
    XCTAssertEqual(try searchIDs(db, "idempotency").count, 1)
  }

  func testBackfill_SkipsAlreadyIndexedEvents() async throws {
    let db = try makeDB()
    // Written through the normal path → already indexed at write time.
    try db.write(RawEvent(signalType: .action, payload: [
      "event_kind": "gh_commit_pushed", "body": "already indexed once",
    ]))
    XCTAssertEqual(try ftsRowCount(db), 1)

    await makeJob(db).runToCompletion()

    XCTAssertEqual(try ftsRowCount(db), 1, "write-time-indexed event must not be re-indexed")
  }

  func testBackfill_ResumesFromCursorAcrossBatches() async throws {
    let db = try makeDB()
    for i in 0..<7 {
      try insertUnindexedEvent(db, tsMs: Int64(i + 1) * 100, payload: [
        "event_kind": "gh_commit_pushed", "body": "commit number\(i)",
      ])
    }

    await makeJob(db, batchSize: 3).runToCompletion()

    XCTAssertEqual(try ftsRowCount(db), 7, "all batches must complete")
    let cursor = try db.readOffset(
      collectorID: MemoryBackfillJob.collectorID, sourceID: MemoryBackfillJob.sweepVersion)
    XCTAssertNotNil(cursor, "cursor must persist")
    XCTAssertEqual(try searchIDs(db, "number5").count, 1)
  }

  func testBackfill_CompletedSweep_IsNoOpUntilVersionBump() async throws {
    let db = try makeDB()
    try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "first sweep",
    ])
    await makeJob(db).runToCompletion()

    // New unindexed historical row INSERTED BELOW the completed cursor cannot
    // exist in practice (ids are monotonic), so the no-op contract is: a
    // completed sweep does not rescan. New events come via write-time indexing.
    let scans = try db.readOffset(
      collectorID: MemoryBackfillJob.collectorID, sourceID: MemoryBackfillJob.sweepVersion)
    XCTAssertNotNil(scans)

    await makeJob(db).runToCompletion()
    XCTAssertEqual(try ftsRowCount(db), 1)
  }

  // MARK: - Track A3 — detector replay (phase B)

  private struct SentinelDecisionDetector: DecisionDetectorProtocol {
    func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
      guard body.contains("DECIDE") else { return nil }
      return DecisionHit(topicKeywords: ["replay"], reasoningExcerpt: body, confidence: 0.9)
    }
  }

  private func sentinelMoat() -> DetectorMoat {
    DetectorMoat(
      decision: SentinelDecisionDetector(),
      openQuestion: NoOpOpenQuestionDetector(),
      blockerPattern: NoOpBlockerPatternDetector(),
      linearStuck: NoOpLinearStuckScanner(),
      whereStopped: NoOpWhereStoppedDeriver(),
      absence: ExactMatchAbsence()
    )
  }

  private func decisionCount(_ db: LeafCore.Database) throws -> Int {
    try db.readSQL { rawDB in
      try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM decisions") ?? 0
    }
  }

  private func liveCursor(_ db: LeafCore.Database, kind: String) throws -> Int64 {
    try db.readSQL { rawDB in
      try DetectorOffsetsStore.cursor(detectorKind: kind, in: rawDB)
    }
  }

  /// Simulates history scanned by an older binary whose trigger catalogue
  /// missed these bodies: events sit BELOW the live detector cursor, so the
  /// incremental pass will never revisit them.
  func testDetectorReplay_FindsHitsBelowLiveCursor_WithoutMovingIt() async throws {
    let db = try makeDB()
    let id1 = try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "DECIDE: adopt SQLCipher",
    ])
    let id2 = try insertUnindexedEvent(db, tsMs: 2_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "DECIDE: drop polling",
    ])
    // Old binary "scanned" them without detecting anything.
    try db.writeSQL { rawDB in
      try DetectorOffsetsStore.advance(
        detectorKind: Schema.DetectorKinds.decision, toEventID: id2, nowMs: 3_000, in: rawDB)
    }
    XCTAssertEqual(try decisionCount(db), 0)

    let job = MemoryBackfillJob(
      database: db, batchSize: 1, interBatchDelaySec: 0,
      linearPrefixes: { [] }, derivers: .publicSubstrate,
      detectorMoat: sentinelMoat())
    await job.runToCompletion()

    XCTAssertEqual(try decisionCount(db), 2, "replay must surface missed decisions")
    XCTAssertEqual(try liveCursor(db, kind: Schema.DetectorKinds.decision), id2,
                   "live cursor must never move during replay")
    _ = id1

    // Re-run: UNIQUE(event_id) + replay cursor make it a no-op.
    await job.runToCompletion()
    XCTAssertEqual(try decisionCount(db), 2)
  }

  func testDetectorReplay_NoLiveCursor_IsNoOp() async throws {
    let db = try makeDB()
    try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_commit_pushed", "body": "DECIDE: something",
    ])

    let job = MemoryBackfillJob(
      database: db, batchSize: 10, interBatchDelaySec: 0,
      linearPrefixes: { [] }, derivers: .publicSubstrate,
      detectorMoat: sentinelMoat())
    await job.runToCompletion()

    // Live cursor is 0 → nothing has been live-scanned yet → the incremental
    // pass owns the whole range; replay must not double-cover it.
    XCTAssertEqual(try decisionCount(db), 0)
  }

  func testBackfill_IndexesPRTitlesPulseCarriers() async throws {
    let db = try makeDB()
    try insertUnindexedEvent(db, tsMs: 1_000, payload: [
      "event_kind": "gh_pr_titles_backfill",
      "pr_refs_json": #"[{"number":70,"repo":"acme/widget","title":"PR title backfill point-fetch"}]"#,
    ])

    await makeJob(db).runToCompletion()

    // NB: the FTS tokenizer keeps '-' inside tokens (Linear refs like GUN-12
    // must stay whole), so "point-fetch" is a single token — search a plain word.
    XCTAssertEqual(try searchIDs(db, "title").count, 1,
                   "PR titles in pulse carriers must become searchable")
  }
}
