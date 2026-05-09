// Phase Track-1 D3 — DetectorPipeline.runScheduled (LinearStuck + WhereStopped).
//
// Sentinel scanner / deriver fixtures live inline (LeafCorePrivate moat impls
// would bring regex / heuristics that aren't the unit under test here). Tests
// assert blocker emission, partial-unique idempotency, auto-resolve when a
// linear status_transition event lands, and where_stopped append/skip behavior.

import XCTest
import GRDB
@testable import LeafCore

final class DetectorPipelineScheduledTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-scheduled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel moat

    private struct SentinelLinearStuckScanner: LinearStuckScannerProtocol {
        var stuckDays: Int { 7 }
        let toReturn: [LinearStuckHit]
        func currentlyStuck(in db: GRDB.Database, nowMs: Int64) throws -> [LinearStuckHit] {
            toReturn
        }
    }

    private struct SentinelWhereStoppedDeriver: WhereStoppedDeriverProtocol {
        var idleSeconds: Int { 60 }
        let output: WhereStoppedOutput?
        func derive(
            in db: GRDB.Database,
            sinceMs: Int64,
            untilMs: Int64
        ) throws -> WhereStoppedOutput? { output }
    }

    private func scheduledMoat(
        stuckHits: [LinearStuckHit] = [],
        whereStoppedOutput: WhereStoppedOutput? = nil
    ) -> DetectorMoat {
        DetectorMoat(
            decision: NoOpDecisionDetector(),
            openQuestion: NoOpOpenQuestionDetector(),
            blockerPattern: NoOpBlockerPatternDetector(),
            linearStuck: SentinelLinearStuckScanner(toReturn: stuckHits),
            whereStopped: SentinelWhereStoppedDeriver(output: whereStoppedOutput),
            absence: ExactMatchAbsence()
        )
    }

    // MARK: - Helpers

    private func openDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(
            at: dbURL,
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    private func writeEvent(
        _ db: LeafCore.Database,
        tsMs: Int64,
        signalType: SignalType = .action,
        payload: [String: String]
    ) throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: signalType,
            bundleID: "test.bundle",
            payload: payload
        )
        try db.write(event)
    }

    private func blockerRows(_ db: LeafCore.Database) throws -> [Row] {
        try db.readSQL { rawDB in
            try Row.fetchAll(rawDB, sql: """
                SELECT id, target_kind, target_ref, blocker_kind,
                       started_at_ms, resolved_at_ms, resolved_by_event_id
                  FROM blockers ORDER BY id ASC
                """)
        }
    }

    private func whereStoppedRows(_ db: LeafCore.Database) throws -> [Row] {
        try db.readSQL { rawDB in
            try Row.fetchAll(rawDB, sql: """
                SELECT id, generated_at_ms, anchor_event_id, excerpt, wip_signals_json
                  FROM where_stopped_log ORDER BY id ASC
                """)
        }
    }

    // MARK: - Tests

    func testLinearStuckEmitsBlocker() throws {
        let db = try openDB()
        let hit = LinearStuckHit(issueRef: "LEAF-1", lastStatusTransitionAtMs: 1_000)
        let moat = scheduledMoat(stuckHits: [hit])

        try DetectorPipeline.runScheduled(moat: moat, nowMs: 9_999, in: db)

        let rows = try blockerRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["target_kind"] as String?, "linear_issue")
        XCTAssertEqual(rows.first?["target_ref"] as String?, "LEAF-1")
        XCTAssertEqual(rows.first?["blocker_kind"] as String?, "linear_stuck")
        XCTAssertEqual(rows.first?["started_at_ms"] as Int64?, 1_000)
        XCTAssertNil(rows.first?["resolved_at_ms"] as Int64?)
    }

    func testLinearStuckAutoResolvesWhenStatusChanges() throws {
        let db = try openDB()

        // Seed an open linear_stuck blocker for LEAF-2 (manually — sentinel that
        // returned [LEAF-2] in a prior run would have produced this row).
        try db.writeSQL { rawDB in
            _ = try BlockersStore.insertOpenIfAbsent(
                targetKind: Schema.TargetKinds.linearIssue,
                targetRef: "LEAF-2",
                blockerKind: "linear_stuck",
                excerpt: nil,
                detectedByEventID: nil,
                startedAtMs: 1_000,
                in: rawDB
            )
        }

        // A recent status_transition event for LEAF-2 — the auto-resolve query
        // matches on payload.event_kind == "status_transition" + issue_key.
        try writeEvent(db, tsMs: 5_000, payload: [
            "event_kind": "status_transition",
            "issue_key": "LEAF-2",
            "to_state_name": "In Review",
            "to_state_type": "started"
        ])

        // Sentinel returns empty list → LEAF-2 is no longer stuck.
        try DetectorPipeline.runScheduled(moat: scheduledMoat(stuckHits: []),
                                          nowMs: 9_999, in: db)

        let rows = try blockerRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["resolved_at_ms"] as Int64?, 5_000,
                       "resolved_at_ms == ts of the status_transition event")
        XCTAssertEqual(rows.first?["resolved_by_event_id"] as Int64?, 1,
                       "resolved_by_event_id == id of the transition event (event #1)")
    }

    func testNoDoubleEmitOnSameRun() throws {
        let db = try openDB()
        let hit = LinearStuckHit(issueRef: "LEAF-3", lastStatusTransitionAtMs: 2_000)
        let moat = scheduledMoat(stuckHits: [hit])

        try DetectorPipeline.runScheduled(moat: moat, nowMs: 9_000, in: db)
        // Second run with the same hit — partial-unique idx_blockers_open
        // (target_kind, target_ref WHERE resolved_at_ms IS NULL) blocks the
        // duplicate insert via INSERT OR IGNORE.
        try DetectorPipeline.runScheduled(moat: moat, nowMs: 9_500, in: db)

        let rows = try blockerRows(db)
        XCTAssertEqual(rows.count, 1, "partial-unique guard prevents double-emit")
    }

    func testWhereStoppedAppendsRowWithIdleAnchor() throws {
        let db = try openDB()
        let output = WhereStoppedOutput(
            excerpt: "stopped on commit message edit",
            wipSignals: WipSignals(commitWip: true, ciFailing: false, midEdit: true),
            anchorEventID: 42
        )
        let moat = scheduledMoat(whereStoppedOutput: output)

        try DetectorPipeline.runScheduled(moat: moat, nowMs: 7_777, in: db)

        let rows = try whereStoppedRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["generated_at_ms"] as Int64?, 7_777)
        XCTAssertEqual(rows.first?["anchor_event_id"] as Int64?, 42)
        XCTAssertEqual(rows.first?["excerpt"] as String?, "stopped on commit message edit")
        let wipJSON = rows.first?["wip_signals_json"] as String?
        XCTAssertNotNil(wipJSON)
        XCTAssertTrue(wipJSON?.contains("\"commitWip\":true") ?? false)
    }

    func testWhereStoppedRespectsIdleSeconds() throws {
        let db = try openDB()
        // Sentinel deriver returns nil — interpret as "not idle enough yet".
        let moat = scheduledMoat(whereStoppedOutput: nil)

        try DetectorPipeline.runScheduled(moat: moat, nowMs: 9_999, in: db)

        let rows = try whereStoppedRows(db)
        XCTAssertEqual(rows.count, 0, "nil derive output → no row appended")
    }
}
