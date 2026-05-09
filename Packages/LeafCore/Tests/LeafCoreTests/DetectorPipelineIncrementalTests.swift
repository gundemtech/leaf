// Phase Track-1 D3 — DetectorPipeline.runIncremental per-event pass.
//
// Sentinel detector moat lives inline (body-substring-based) so the public
// substrate's no-op detectors don't gate test coverage. Tests assert
// cursor advancement, INSERT-OR-IGNORE idempotency, body-kind dispatch +
// context-ref population for OpenQuestion / Decision / Blocker writes.

import XCTest
import GRDB
@testable import LeafCore

final class DetectorPipelineIncrementalTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel moat

    private struct SentinelDecisionDetector: DecisionDetectorProtocol {
        func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
            guard body.contains("DECIDE") else { return nil }
            return DecisionHit(topicKeywords: ["sentinel"],
                               reasoningExcerpt: body, confidence: 0.9)
        }
    }

    private struct SentinelOpenQuestionDetector: OpenQuestionDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> OpenQuestionHit? {
            guard body.contains("QUESTION") else { return nil }
            return OpenQuestionHit(questionExcerpt: body, alternatives: nil)
        }
    }

    private struct SentinelBlockerPatternDetector: BlockerPatternDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> BlockerPatternHit? {
            guard body.contains("BLOCKED") else { return nil }
            return BlockerPatternHit(blockerExcerpt: body)
        }
    }

    private func sentinelMoat() -> DetectorMoat {
        DetectorMoat(
            decision: SentinelDecisionDetector(),
            openQuestion: SentinelOpenQuestionDetector(),
            blockerPattern: SentinelBlockerPatternDetector(),
            linearStuck: NoOpLinearStuckScanner(),
            whereStopped: NoOpWhereStoppedDeriver(),
            absence: ExactMatchAbsence()
        )
    }

    // MARK: - Helpers

    private func openDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func writeEvent(_ db: LeafCore.Database,
                            tsMs: Int64,
                            signalType: SignalType = .action,
                            payload: [String: String]) throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: signalType,
            bundleID: "test.bundle",
            payload: payload
        )
        try db.write(event)
    }

    private func cursor(_ db: LeafCore.Database, kind: String) throws -> Int64 {
        try db.readSQL { rawDB in
            try Int64.fetchOne(rawDB, sql:
                "SELECT cursor_event_id FROM detector_offsets WHERE detector_kind = ?",
                arguments: [kind]) ?? -1
        }
    }

    private func decisionCount(_ db: LeafCore.Database) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM decisions") ?? 0
        }
    }

    private func openQuestionRows(_ db: LeafCore.Database) throws -> [Row] {
        try db.readSQL { rawDB in
            try Row.fetchAll(rawDB, sql: """
                SELECT event_id, question_excerpt, slack_thread_ts,
                       linear_issue_ref, github_pr_ref
                  FROM open_questions ORDER BY id ASC
                """)
        }
    }

    private func blockerRows(_ db: LeafCore.Database) throws -> [Row] {
        try db.readSQL { rawDB in
            try Row.fetchAll(rawDB, sql: """
                SELECT target_kind, target_ref, blocker_kind,
                       blocker_excerpt, detected_by_event_id, started_at_ms
                  FROM blockers ORDER BY id ASC
                """)
        }
    }

    // MARK: - Tests

    func testCursorAdvancesPastProcessedEvents() throws {
        let db = try openDB()
        // 3 plain events, no body — cursor должен advance до последнего id.
        try writeEvent(db, tsMs: 1_000, payload: ["event_kind": "linear_issue_updated"])
        try writeEvent(db, tsMs: 2_000, payload: ["event_kind": "linear_issue_updated"])
        try writeEvent(db, tsMs: 3_000, payload: ["event_kind": "linear_issue_updated"])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        XCTAssertEqual(try cursor(db, kind: "decision"), 3)
        XCTAssertEqual(try cursor(db, kind: "open_question"), 3)
        XCTAssertEqual(try cursor(db, kind: "blocker_pattern"), 3)
    }

    func testInsertOrIgnoreOnReRun() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 1_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "DECIDE to ship"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)
        XCTAssertEqual(try decisionCount(db), 1)

        // Reset cursor to force backfill — INSERT OR IGNORE keeps row count flat.
        try db.writeSQL { rawDB in
            try rawDB.execute(sql:
                "UPDATE detector_offsets SET cursor_event_id = 0 WHERE detector_kind = 'decision'")
        }
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)
        XCTAssertEqual(try decisionCount(db), 1, "INSERT OR IGNORE per-event idempotency on backfill")
    }

    func testDecisionWriteForLinearDesc() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 1_500, payload: [
            "event_kind": "linear_issue_updated",
            "body": "We DECIDE to use SQLCipher"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        let row = try db.readSQL { rawDB in
            try Row.fetchOne(rawDB, sql: """
                SELECT event_id, reasoning_excerpt, confidence, detected_at_ms
                  FROM decisions
                """)
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["event_id"] as Int64?, 1)
        XCTAssertEqual(row?["reasoning_excerpt"] as String?, "We DECIDE to use SQLCipher")
        XCTAssertEqual(row?["confidence"] as Double?, 0.9)
        XCTAssertEqual(row?["detected_at_ms"] as Int64?, 1_500)
    }

    func testDecisionWriteForCommitMsg() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 2_500, payload: [
            "event_kind": "commit_pushed",
            "body": "feat: DECIDE on EdDSA signing"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        let count = try decisionCount(db)
        XCTAssertEqual(count, 1, "commit_pushed body → commitMsg → decision")
    }

    func testOpenQuestionWritePopulatesSlackThreadTS() throws {
        let db = try openDB()
        // slack_thread_reply_aggregate event with thread_ts + body containing QUESTION.
        try writeEvent(db, tsMs: 4_000, signalType: .action, payload: [
            "event_kind": "slack_thread_reply_aggregate",
            "body": "Should we go QUESTION-style or polling?",
            "thread_ts": "1700000000.001234"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        let rows = try openQuestionRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["slack_thread_ts"] as String?, "1700000000.001234")
        XCTAssertNil(rows.first?["linear_issue_ref"] as String?)
        XCTAssertNil(rows.first?["github_pr_ref"] as String?)
    }

    func testOpenQuestionWritePopulatesLinearIssueRef() throws {
        let db = try openDB()
        // linear_issue_updated with linked_linear_id payload key (Phase 4.7.A)
        try writeEvent(db, tsMs: 5_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "Open QUESTION: which encryption?",
            "linked_linear_id": "LEAF-42"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        let rows = try openQuestionRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["linear_issue_ref"] as String?, "LEAF-42")
    }

    func testBlockerPatternWritePopulatesDetectedByEventID() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 6_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "We are BLOCKED on the migration",
            "linked_linear_id": "LEAF-7"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        let rows = try blockerRows(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["target_kind"] as String?, "linear_issue")
        XCTAssertEqual(rows.first?["target_ref"] as String?, "LEAF-7")
        XCTAssertEqual(rows.first?["detected_by_event_id"] as Int64?, 1)
        XCTAssertEqual(rows.first?["started_at_ms"] as Int64?, 6_000)
        XCTAssertEqual(rows.first?["blocker_kind"] as String?, "pattern_blocked_on")
    }

    func testBackfillAfterCursorReset() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 1_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "DECIDE on relay design"
        ])
        try writeEvent(db, tsMs: 2_000, payload: [
            "event_kind": "commit_pushed",
            "body": "no signal here"
        ])

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)
        XCTAssertEqual(try decisionCount(db), 1)
        XCTAssertEqual(try cursor(db, kind: "decision"), 2)

        // Add new event after first run, then reset cursor → backfill must re-process
        // both events without duplicating decision row.
        try writeEvent(db, tsMs: 3_000, payload: [
            "event_kind": "commit_pushed",
            "body": "DECIDE: ship alpha.12"
        ])
        try db.writeSQL { rawDB in
            try rawDB.execute(sql:
                "UPDATE detector_offsets SET cursor_event_id = 0")
        }

        try DetectorPipeline.runIncremental(moat: sentinelMoat(), nowMs: 9_999, in: db)

        XCTAssertEqual(try decisionCount(db), 2, "first decision idempotent; second new")
        XCTAssertEqual(try cursor(db, kind: "decision"), 3)
    }
}
