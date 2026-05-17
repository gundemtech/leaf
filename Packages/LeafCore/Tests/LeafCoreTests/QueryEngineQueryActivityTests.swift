// Phase Track-1 D3 — QueryEngine.queryActivity composition tests.
//
// Covers FTS-routed filter branch, no-filter recent-events branch, SQL LIMIT
// 200 backstop, post-serialize 64KB byte budget trim, decisions /
// open_questions / blockers / links composition, and on-the-fly absence flags.
// Sentinel detector moat lives inline so test assertions don't depend on the
// public-substrate no-op detectors / matcher.

import GRDB
import XCTest

@testable import LeafCore

final class QueryEngineQueryActivityTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-query-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel moat (mirrors DetectorPipelineIncrementalTests)

    private struct SentinelDecisionDetector: DecisionDetectorProtocol {
        func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
            guard body.contains("DECIDE") else { return nil }
            return DecisionHit(topicKeywords: ["sentinel"], reasoningExcerpt: body, confidence: 0.9)
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

    /// Returns `nil` for any login NOT in `knownMatches`. Lets the test stub a
    /// confident match for some reviewers and an absence for others.
    private struct StubAbsenceMatcher: AbsenceMatcherProtocol {
        let knownMatches: Set<String>
        func match(githubLogin: String, slackIdentifiers: [SlackIdentifier]) -> SlackIdentifier? {
            knownMatches.contains(githubLogin) ? slackIdentifiers.first : nil
        }
    }

    private func sentinelMoat(absence: any AbsenceMatcherProtocol = ExactMatchAbsence()) -> DetectorMoat {
        DetectorMoat(
            decision: SentinelDecisionDetector(),
            openQuestion: SentinelOpenQuestionDetector(),
            blockerPattern: SentinelBlockerPatternDetector(),
            linearStuck: NoOpLinearStuckScanner(),
            whereStopped: NoOpWhereStoppedDeriver(),
            absence: absence
        )
    }

    // MARK: - Helpers

    private func openWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeEngine(absence: any AbsenceMatcherProtocol = ExactMatchAbsence()) -> QueryEngine {
        QueryEngine(
            dbURL: dbURL,
            dbConfig: .weakDefaults,
            dbEncryption: .deterministicTest,
            detectorMoat: sentinelMoat(absence: absence)
        )
    }

    private func writeEvent(
        _ db: LeafCore.Database,
        tsMs: Int64,
        signalType: SignalType = .action,
        bundleID: String? = "test.bundle",
        payload: [String: String]
    ) throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: signalType,
            bundleID: bundleID,
            payload: payload
        )
        try db.write(event, knownLinearPrefixes: ["LEAF"])
    }

    private func widePeriod() -> PeriodSpec {
        PeriodSpec(startMs: 0, endMs: Int64(Date().timeIntervalSince1970 * 1000) + 10_000_000)
    }

    // MARK: - 1. Filter routes through FTS

    func testWithFilter_RoutesThroughFTS() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                Schema.EventPayloadKeys.body: "auth refactor — moved refresh logic",
            ])
        try writeEvent(
            db, tsMs: 2_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                Schema.EventPayloadKeys.body: "unrelated payments hotfix",
            ])

        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: "auth")

        XCTAssertEqual(response.schemaVersion, "1.0")
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events.first?.bodyExcerpt, "auth refactor — moved refresh logic")
        XCTAssertEqual(response.filter, "auth")
    }

    // MARK: - 2. No filter → recent-events SELECT

    func testWithoutFilter_ReturnsRecentEventsInPeriod() throws {
        let db = try openWriter()
        try writeEvent(db, tsMs: 1_000, payload: ["event_kind": "x"])
        try writeEvent(db, tsMs: 2_000, payload: ["event_kind": "y"])
        try writeEvent(db, tsMs: 5_000, payload: ["event_kind": "z"])

        let engine = makeEngine()
        let response = try engine.queryActivity(
            period: PeriodSpec(startMs: 1_500, endMs: 4_000),
            filter: nil
        )
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events.first?.eventKind, "y")
    }

    // MARK: - 3. SQL LIMIT 200 hard cap

    func testSQLLimit200_HardCap() throws {
        let db = try openWriter()
        for i in 1...250 {
            try writeEvent(db, tsMs: Int64(i), payload: ["event_kind": "noise"])
        }
        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)
        XCTAssertEqual(response.events.count, 200, "SQL LIMIT 200 must cap before byte-budget trim")
    }

    // MARK: - 4. Byte budget trims oldest events

    func testByteBudget64KB_TrimsOldestEvents() throws {
        let db = try openWriter()
        // 200 events × ~500-byte body = ~100KB raw → guarantees over-budget.
        let bigBody = String(repeating: "x", count: 600)
        for i in 1...200 {
            try writeEvent(
                db, tsMs: Int64(i),
                payload: [
                    "event_kind": "gh_commit_pushed",
                    Schema.EventPayloadKeys.body: bigBody,
                ])
        }
        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)

        XCTAssertLessThan(response.events.count, 200, "Byte budget must trim some events")
        XCTAssertGreaterThan(
            response.events.count, 0, "Byte budget should keep a non-zero event count for moderate payloads")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(response).count
        XCTAssertLessThanOrEqual(bytes, 65_536)
    }

    // MARK: - 5. truncationNote shape

    func testTruncationNoteOnTrim() throws {
        let db = try openWriter()
        let bigBody = String(repeating: "y", count: 600)
        for i in 1...200 {
            try writeEvent(
                db, tsMs: Int64(i),
                payload: [
                    "event_kind": "gh_commit_pushed",
                    Schema.EventPayloadKeys.body: bigBody,
                ])
        }
        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)

        guard let note = response.truncationNote else {
            return XCTFail("Expected truncationNote when events trimmed by byte budget")
        }
        XCTAssertEqual(note.reason, "byte_budget")
        XCTAssertEqual(note.originalCount, 200)
        XCTAssertEqual(note.returnedCount, response.events.count)
        // events ordered ts DESC → last entry is the oldest kept
        XCTAssertEqual(note.oldestReturnedTsMs, response.events.last?.tsMs)
    }

    // MARK: - 6. Decisions composition

    func testDecisionsInPeriodComposition() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "DECIDE: ship without reviewer ack",
            ])
        // Run detectors over the seeded events so `decisions` table is populated.
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)
        XCTAssertEqual(response.decisionsInPeriod.count, 1)
        XCTAssertTrue(response.decisionsInPeriod.first?.reasoningExcerpt.contains("DECIDE") ?? false)
    }

    // MARK: - 7. Open questions composition

    func testOpenQuestionsComposition() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "QUESTION should we use Postgres or Redis?",
                "thread_ts": "1700000000.001",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)
        XCTAssertEqual(response.openQuestions.count, 1)
        XCTAssertEqual(response.openQuestions.first?.slackThreadTS, "1700000000.001")
        XCTAssertNil(response.openQuestions.first?.resolvedAtMs)
    }

    // MARK: - 8. Blockers composition

    func testBlockersComposition() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "BLOCKED on infra team waking up",
                "linked_github_pr": "owner/repo/pull/42",
            ])
        try DetectorPipeline.runIncremental(moat: sentinelMoat(), in: db)

        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)
        XCTAssertEqual(response.blockers.count, 1)
        XCTAssertEqual(response.blockers.first?.blockerKind, Schema.BlockerKinds.patternBlockedOn)
        XCTAssertEqual(response.blockers.first?.targetKind, Schema.TargetKinds.githubPR)
    }

    // MARK: - 9. Links composition

    func testLinksComposition() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                Schema.EventPayloadKeys.body: "LEAF-42 implement auth refactor",
            ])
        let engine = makeEngine()
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)
        // LinearIDExtractor pulls "LEAF-42" → linear_id_in_text link.
        XCTAssertTrue(
            response.links.contains { $0.targetRef == "LEAF-42" },
            "Expected LEAF-42 link from commit body, got \(response.links)")
    }

    // MARK: - 10. Absence flag fuzz match success + failure

    func testAbsenceFlagComputation_FuzzMatchSucceedsAndFails() throws {
        let db = try openWriter()
        // 1) PR event with two reviewers; one matches, one doesn't.
        let reviewersJSON = "[\"alice\",\"bob\"]"
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "gh_pr_opened",
                Schema.EventPayloadKeys.body: "Adopt new auth scheme — design choice excerpt",
                "linked_github_pr": "owner/repo/pull/142",
                Schema.EventPayloadKeys.requestedReviewersJson: reviewersJSON,
            ])
        // 2) Slack thread event linked to the same PR (so eventsLinkingTo finds it).
        try writeEvent(
            db, tsMs: 6_000, signalType: .action,
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                Schema.EventPayloadKeys.body: "discussion about https://github.com/owner/repo/pull/142",
                "user_id": "alice",
            ])
        // Manually insert a link from the Slack event to the PR (avoids
        // pulling LeafCorePrivate URL extractor into the test).
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                        INSERT OR IGNORE INTO event_links
                            (from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    2,
                    Schema.LinkKinds.prURLInSlack,
                    Schema.TargetKinds.githubPR,
                    "owner/repo/pull/142",
                    0.5,
                    6_000,
                ])
        }

        let engine = makeEngine(absence: StubAbsenceMatcher(knownMatches: ["alice"]))
        let response = try engine.queryActivity(period: widePeriod(), filter: nil)

        // alice matches (no flag), bob doesn't (one flag emitted).
        let bobFlag = response.absenceFlags.first { $0.reviewerLogin == "bob" }
        XCTAssertNotNil(bobFlag, "Expected absence flag for bob, got \(response.absenceFlags)")
        XCTAssertEqual(bobFlag?.prRef, "owner/repo/pull/142")
        XCTAssertEqual(bobFlag?.lastThreadActivityMs, 6_000)
        XCTAssertFalse(response.absenceFlags.contains { $0.reviewerLogin == "alice" })
    }
}
