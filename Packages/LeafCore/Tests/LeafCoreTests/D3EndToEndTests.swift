// Phase Track-1 D3 — Agent integration end-to-end shape tests.
//
// These tests don't spin up the LaunchAgent. They validate the SHAPES that
// Agent's periodic timers will invoke: `DetectorPipeline.runIncremental` after
// collector flushes (via the periodic detector timer) and
// `DetectorPipeline.runScheduled` from the idle-scheduler timer. Sentinel moats
// stand in for LeafCorePrivate prod detectors so the substrate's no-op
// impls don't gate coverage.
//
// Asserts the full D3 chain end-to-end: events written → detector pass →
// detector tables populated → QueryEngine.queryActivity composes the response.

import XCTest
import GRDB
@testable import LeafCore

final class D3EndToEndTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel moats

    private struct SentinelDecisionDetector: DecisionDetectorProtocol {
        func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
            guard body.contains("DECIDE-SENTINEL") else { return nil }
            return DecisionHit(topicKeywords: ["sentinel"],
                               reasoningExcerpt: body, confidence: 0.9)
        }
    }
    private struct SentinelOpenQuestionDetector: OpenQuestionDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> OpenQuestionHit? {
            guard body.contains("QUESTION-SENTINEL") else { return nil }
            return OpenQuestionHit(questionExcerpt: body, alternatives: nil)
        }
    }
    private struct SentinelBlockerPatternDetector: BlockerPatternDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> BlockerPatternHit? {
            guard body.contains("BLOCKED-SENTINEL") else { return nil }
            return BlockerPatternHit(blockerExcerpt: body)
        }
    }

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
        func derive(in db: GRDB.Database,
                    sinceMs: Int64,
                    untilMs: Int64) throws -> WhereStoppedOutput? { output }
    }

    private func incrementalMoat() -> DetectorMoat {
        DetectorMoat(
            decision: SentinelDecisionDetector(),
            openQuestion: SentinelOpenQuestionDetector(),
            blockerPattern: SentinelBlockerPatternDetector(),
            linearStuck: NoOpLinearStuckScanner(),
            whereStopped: NoOpWhereStoppedDeriver(),
            absence: ExactMatchAbsence()
        )
    }

    private func scheduledMoat(stuckHits: [LinearStuckHit],
                               whereStoppedOutput: WhereStoppedOutput?) -> DetectorMoat {
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
        try LeafCore.Database.openForWrite(at: dbURL,
                                           config: .weakDefaults,
                                           encryption: .deterministicTest)
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

    // MARK: - 1. Collector flush → DetectorPipeline.runIncremental → decision row

    /// Asserts the shape Agent's periodic detector timer invokes:
    /// after a collector writes events, the next detector tick produces a
    /// `decisions` row for any body matching the sentinel.
    func testCollectorFlushTriggersDetectorPipeline_DecisionEmitted() throws {
        let db = try openDB()
        try writeEvent(db, tsMs: 1_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "We DECIDE-SENTINEL to ship D3"
        ])

        // Emulates what Agent's periodic detector timer will call.
        try DetectorPipeline.runIncremental(moat: incrementalMoat(),
                                            nowMs: 9_999,
                                            in: db)

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM decisions") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - 2. Idle scheduler → DetectorPipeline.runScheduled → blocker + where_stopped

    /// Asserts the shape Agent's idle scheduler timer invokes:
    /// `runScheduled` writes a `linear_stuck` blocker for each stuck hit AND
    /// appends one `where_stopped_log` row when the deriver emits.
    func testIdleSchedulerEmitsLinearStuckAndWhereStopped() throws {
        let db = try openDB()
        let stuckHit = LinearStuckHit(issueRef: "LEAF-99",
                                      lastStatusTransitionAtMs: 1_000)
        let wsOutput = WhereStoppedOutput(
            excerpt: "Working on LeafAgent.swift",
            wipSignals: WipSignals(commitWip: false, ciFailing: false, midEdit: true),
            anchorEventID: nil
        )

        try DetectorPipeline.runScheduled(
            moat: scheduledMoat(stuckHits: [stuckHit], whereStoppedOutput: wsOutput),
            nowMs: 9_999, in: db)

        let blockerCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM blockers WHERE blocker_kind = ?",
                arguments: [Schema.BlockerKinds.linearStuck]) ?? 0
        }
        XCTAssertEqual(blockerCount, 1)

        let wsCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM where_stopped_log") ?? 0
        }
        XCTAssertEqual(wsCount, 1)
    }

    // MARK: - 3. End-to-end: detector pass → QueryEngine.queryActivity composes everything

    /// Seeds events that hit each detector (decision + open question + blocker),
    /// runs the same `runIncremental` Agent's timer will run, then asks
    /// `QueryEngine.queryActivity` to compose the response. Asserts
    /// detector tables flow through to the structured MCP response shape.
    func testQueryActivityComposesAcrossAllDetectorOutputs() throws {
        let db = try openDB()

        // Seed: 1 plain noise + 3 detector hits + 1 more noise.
        try writeEvent(db, tsMs: 1_000, payload: ["event_kind": "linear_issue_updated"])
        try writeEvent(db, tsMs: 2_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "We DECIDE-SENTINEL to use SQLCipher"
        ])
        try writeEvent(db, tsMs: 3_000, payload: [
            "event_kind": "slack_thread_reply_aggregate",
            "body": "Open QUESTION-SENTINEL: which encryption?",
            "thread_ts": "1700000000.001"
        ])
        try writeEvent(db, tsMs: 4_000, payload: [
            "event_kind": "linear_issue_updated",
            "body": "BLOCKED-SENTINEL waiting on infra",
            "linked_linear_id": "LEAF-7"
        ])
        try writeEvent(db, tsMs: 5_000, payload: ["event_kind": "linear_issue_updated"])

        try DetectorPipeline.runIncremental(moat: incrementalMoat(),
                                            nowMs: 9_999,
                                            in: db)

        let engine = QueryEngine(
            dbURL: dbURL,
            dbConfig: .weakDefaults,
            dbEncryption: .deterministicTest,
            detectorMoat: incrementalMoat()
        )
        let response = try engine.queryActivity(
            period: PeriodSpec(startMs: 0, endMs: 10_000),
            filter: nil
        )

        XCTAssertFalse(response.events.isEmpty,
                       "events[] must be populated for the seed period")
        XCTAssertEqual(response.decisionsInPeriod.count, 1,
                       "DECIDE body → 1 decision row composed into response")
        XCTAssertEqual(response.openQuestions.count, 1,
                       "QUESTION body → 1 open_question row composed into response")
        XCTAssertEqual(response.blockers.count, 1,
                       "BLOCKED body → 1 blocker row composed into response")
        // links may be empty (no extractor moat in publicSubstrate write path);
        // assert non-nil to confirm the composition shape is wired.
        XCTAssertNotNil(response.links)
    }
}
