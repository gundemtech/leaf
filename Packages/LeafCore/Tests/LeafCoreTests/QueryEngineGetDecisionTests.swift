// Phase Track-1 D3 — QueryEngine.getDecision composition tests.
//
// Verifies FTS-over-event-bodies routing, nil response on no match, related
// events derived from EventLinksStore reverse lookup, period scoping, and
// confidence-then-recency ranking.

import GRDB
import XCTest

@testable import LeafCore

final class QueryEngineGetDecisionTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-get-decision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel detector (only DecisionDetector matters here)

    private struct SentinelDecisionDetector: DecisionDetectorProtocol {
        func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
            guard body.contains("DECIDE") else { return nil }
            return DecisionHit(topicKeywords: ["sentinel"], reasoningExcerpt: body, confidence: 0.9)
        }
    }
    private struct SentinelOpenQuestionDetector: OpenQuestionDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> OpenQuestionHit? { nil }
    }
    private struct SentinelBlockerPatternDetector: BlockerPatternDetectorProtocol {
        func detect(body: String, kind: BodyKind) -> BlockerPatternHit? { nil }
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

    private func openWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeEngine() -> QueryEngine {
        QueryEngine(
            dbURL: dbURL,
            dbConfig: .weakDefaults,
            dbEncryption: .deterministicTest,
            detectorMoat: sentinelMoat()
        )
    }

    private func writeEvent(
        _ db: LeafCore.Database,
        tsMs: Int64,
        payload: [String: String]
    ) throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: .action,
            bundleID: "test.bundle",
            payload: payload
        )
        try db.write(event, knownLinearPrefixes: ["LEAF"])
    }

    /// Inserts a synthetic decision row directly so test scenarios can encode
    /// confidence/recency tie-breaks without depending on detector cadence.
    private func insertDecision(
        _ db: LeafCore.Database,
        eventID: Int64,
        excerpt: String,
        confidence: Double,
        detectedAtMs: Int64
    ) throws {
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                        INSERT INTO decisions
                            (event_id, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                    """, arguments: [eventID, "[\"manual\"]", excerpt, confidence, detectedAtMs])
        }
    }

    // MARK: - 1. Topic match uses FTS over event bodies

    func testTopicMatchUsesFTSOverReasoningExcerpts() throws {
        let db = try openWriter()
        // Two events: only one has the "OAuth" topic in its body.
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE move OAuth refresh server-side",
            ])
        try writeEvent(
            db, tsMs: 2_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE rename payments module",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let response = try makeEngine().getDecision(topic: "OAuth", period: nil)
        guard let detail = response.decision else {
            return XCTFail("Expected a decision matching topic 'OAuth'")
        }
        XCTAssertTrue(detail.decision.reasoningExcerpt.contains("OAuth"))
        XCTAssertEqual(response.schemaVersion, "1.0")
    }

    // MARK: - 2. Returns nil when no FTS match

    func testReturnsNilWhenNoMatch() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE move OAuth refresh server-side",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let response = try makeEngine().getDecision(topic: "kubernetes", period: nil)
        XCTAssertNil(response.decision)
        XCTAssertTrue(response.relatedEvents.isEmpty)
    }

    // MARK: - 3. Related events via EventLinksStore.linksFrom

    func testRelatedEventsViaLinks() throws {
        let db = try openWriter()
        // Event 1 = the decision body, mentions LEAF-100 (auto-linked to linear_issue).
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE LEAF-100 use Postgres",
            ])
        // Event 2 = subsequent commit also referencing LEAF-100 — should appear in relatedEvents.
        try writeEvent(
            db, tsMs: 2_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                Schema.EventPayloadKeys.body: "LEAF-100 wire Postgres adapter",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let response = try makeEngine().getDecision(topic: "Postgres", period: nil)
        guard let detail = response.decision else {
            return XCTFail("Expected a decision matching 'Postgres'")
        }
        // linksToImplementation derived from the originating event's outbound
        // event_links rows.
        XCTAssertTrue(detail.linksToImplementation.contains { $0.targetRef == "LEAF-100" })
        // relatedEvents contains the commit (event 2) that also references LEAF-100.
        XCTAssertTrue(response.relatedEvents.contains { $0.eventID != detail.decision.eventID })
    }

    // MARK: - 4. Period scoping

    func testPeriodFilterScoping() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE OAuth migration",
            ])
        try writeEvent(
            db, tsMs: 9_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE OAuth follow-up patch",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        // Narrow period: only the second decision should be reachable.
        let response = try makeEngine().getDecision(
            topic: "OAuth",
            period: PeriodSpec(startMs: 5_000, endMs: 10_000)
        )
        guard let detail = response.decision else {
            return XCTFail("Expected a decision in narrowed period")
        }
        XCTAssertTrue(detail.decision.reasoningExcerpt.contains("follow-up"))
    }

    // MARK: - 5. Ranks by confidence DESC, ties broken by recency

    func testRanksByConfidenceTieBrokenByRecency() throws {
        let db = try openWriter()
        // Two events whose body contains the topic word so both candidate via FTS.
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE choose Postgres for billing",
            ])
        try writeEvent(
            db, tsMs: 2_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE switch to Postgres for analytics",
            ])
        // Manually insert decisions with different confidences so ranking is deterministic.
        try insertDecision(db, eventID: 1, excerpt: "lower confidence", confidence: 0.4, detectedAtMs: 9_999)
        try insertDecision(db, eventID: 2, excerpt: "higher confidence", confidence: 0.9, detectedAtMs: 1_000)

        let response = try makeEngine().getDecision(topic: "Postgres", period: nil)
        XCTAssertEqual(
            response.decision?.decision.reasoningExcerpt, "higher confidence",
            "Higher confidence must win regardless of recency")
    }
}
