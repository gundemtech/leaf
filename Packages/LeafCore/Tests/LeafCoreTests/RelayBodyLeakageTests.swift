// Phase Track-1 D1 — privacy regression: bodies must never reach presence_state JSON.
// Acceptance gate per Track 1 contract §6 (bodies on-device only — relay never sees).
//
// Phase Track-1 D3 — extension: detector excerpts (decision / open_question /
// blocker / where_stopped) must also stay on-device. DetectorPipeline runs
// in a separate timer-driven invocation (see Commit 9), not embedded in the
// write helper, so the tests below call `runIncremental` / `runScheduled`
// explicitly after the write.

import XCTest
import GRDB
@testable import LeafCore

final class RelayBodyLeakageTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d1-leakage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeOffset(collectorID: String, sourceID: String, nowMs: Int64) -> CollectorOffset {
        CollectorOffset(
            collectorID: collectorID,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: nowMs,
            updatedMs: nowMs
        )
    }

    func testEventBodyDoesNotLeakIntoPresenceState_Linear() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let bodyText = "SECRET-LINEAR-BODY-MARKER-12345"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "issue_updated",
                "issue_key": "LEA-100",
                Schema.EventPayloadKeys.body: bodyText
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 3, "active_cycle_progress": 0.5]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")
            let stateJSON = (row?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after upsert")
            XCTAssertFalse(stateJSON.contains(bodyText),
                           "Body string MUST NOT appear in presence_state.state_json")
            XCTAssertFalse(stateJSON.contains("\"body\""),
                           "Payload key 'body' should not appear in presence_state.state_json")
        }
    }

    func testEventBodyDoesNotLeakIntoPresenceState_GitHub() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let bodyText = "SECRET-GITHUB-PR-BODY-MARKER-67890"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.github.github",
            payload: [
                "event_kind": "gh_pr_opened",
                "repo": "o/r",
                Schema.EventPayloadKeys.body: bodyText,
                Schema.EventPayloadKeys.additions: "50"
            ]
        )
        let presenceState: [String: Any] = ["my_open_prs": 2]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")
            let stateJSON = (row?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(bodyText))
        }
    }

    func testEventBodyDoesNotLeakIntoPresenceState_Slack() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let messageText = "SECRET-SLACK-MESSAGE-MARKER-X"
        let threadReplyText = "SECRET-SLACK-THREAD-REPLY-Y"
        let parentText = "SECRET-SLACK-PARENT-MARKER-Z"
        let messagesJSON = #"[{"ts":"1.1","text":"\#(messageText)","threadTs":null,"attachments":[]}]"#
        let threadReplies = #"[{"ts":"2.2","text":"\#(threadReplyText)","threadTs":"1.0","attachments":[]}]"#
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event1 = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.tinyspeck.slackmacgap",
            payload: [
                "event_kind": "slack_message_authored_aggregate",
                "channel_name": "general",
                Schema.EventPayloadKeys.messagesJson: messagesJSON
            ]
        )
        let event2 = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.tinyspeck.slackmacgap",
            payload: [
                "event_kind": "slack_thread_reply_aggregate",
                "channel_name": "general",
                Schema.EventPayloadKeys.body: parentText,
                Schema.EventPayloadKeys.threadRepliesJson: threadReplies
            ]
        )
        let presenceState: [String: Any] = ["presence": "active", "dnd": false]
        try db.writeEventsOffsetAndPresence(
            [event1, event2],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='slack'")
            let stateJSON = (row?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(messageText))
            XCTAssertFalse(stateJSON.contains(threadReplyText))
            XCTAssertFalse(stateJSON.contains(parentText))
        }
    }

    func testEventLinksTargetRef_DoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "discusses LEAF-127"
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 7]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            knownLinearPrefixes: ["LEAF"],
            nowMs: nowMs
        )

        // Confirm the link DID get derived (otherwise the assertion below is vacuous).
        let linkCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM event_links WHERE target_ref = ?",
                             arguments: ["LEAF-127"]) ?? 0
        }
        XCTAssertEqual(linkCount, 1, "Sanity: link should exist before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains("LEAF-127"),
                           "event_links target_ref MUST NOT leak into presence_state.state_json")
        }
    }

    func testFTSBodies_DoNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyText = "SECRET-FTS-BODY-MARKER-99887"
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: bodyText
            ]
        )
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: ["assigned_count": 1], derivedMode: nil),
            knownLinearPrefixes: [],
            nowMs: nowMs
        )

        // Confirm body was indexed in FTS (sanity). Contentless FTS5 stores no column data,
        // so we sanity-check via the sidecar meta table written atomically with each FTS row.
        let ftsCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                             arguments: [Schema.BodyKinds.linearDesc]) ?? 0
        }
        XCTAssertEqual(ftsCount, 1, "Sanity: body should be indexed before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(bodyText),
                           "FTS-indexed body MUST NOT appear in presence_state.state_json")
        }
    }

    func testCrossDatabaseIsolation_FTSAndEventLinks_NotInPresenceFlow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // GitHub event with a PR body containing LEAF-450 and a Slack-style PR URL marker.
        let prBody = "Adds support for LEAF-450 — see https://github.com/o/r/pull/9 for context"
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "github",
            payload: [
                "event_kind": "gh_pr_opened",
                Schema.EventPayloadKeys.body: prBody,
                Schema.EventPayloadKeys.requestedReviewersJson: #"["alice"]"#,
                Schema.EventPayloadKeys.additions: "10",
                Schema.EventPayloadKeys.deletions: "2"
            ]
        )

        // Presence carries only structured PR metrics — no body text, no link refs.
        let presenceState: [String: Any] = [
            "review_count": 1,
            "additions": 10,
            "deletions": 2
        ]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: presenceState, derivedMode: nil),
            knownLinearPrefixes: ["LEAF"],
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            // Body text MUST NOT be in presence_state.
            XCTAssertFalse(stateJSON.contains("Adds support"),
                           "PR body excerpt must not appear in presence_state")
            XCTAssertFalse(stateJSON.contains(prBody),
                           "PR body must not appear in presence_state")
            // Link target_refs MUST NOT be in presence_state.
            XCTAssertFalse(stateJSON.contains("LEAF-450"),
                           "Linear ID target_ref must not appear in presence_state")
            XCTAssertFalse(stateJSON.contains("o/r/pull/9"),
                           "PR URL target_ref must not appear in presence_state")
            XCTAssertFalse(stateJSON.contains("alice"),
                           "Reviewer login target_ref must not appear in presence_state")
        }
    }

    // MARK: - D3 detector sentinel moats
    //
    // Inline body-substring stubs so the public substrate's no-op detectors
    // don't gate test coverage. Each stub emits a hit whose excerpt embeds
    // the sentinel; the tests then assert the sentinel reaches the detector
    // table (positive — confirms pipeline ran) but NEVER reaches
    // `presence_state.state_json` (the privacy invariant).

    private struct SentinelDecisionMoat: DecisionDetectorProtocol {
        let sentinel: String
        func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? {
            guard body.contains(sentinel) else { return nil }
            return DecisionHit(topicKeywords: ["sentinel"],
                               reasoningExcerpt: "Decision: \(sentinel)",
                               confidence: 0.9)
        }
    }

    private struct SentinelOpenQuestionMoat: OpenQuestionDetectorProtocol {
        let sentinel: String
        func detect(body: String, kind: BodyKind) -> OpenQuestionHit? {
            guard body.contains(sentinel) else { return nil }
            return OpenQuestionHit(questionExcerpt: "Question: \(sentinel)",
                                   alternatives: nil)
        }
    }

    private struct SentinelBlockerPatternMoat: BlockerPatternDetectorProtocol {
        let sentinel: String
        func detect(body: String, kind: BodyKind) -> BlockerPatternHit? {
            guard body.contains(sentinel) else { return nil }
            return BlockerPatternHit(blockerExcerpt: "Blocker: \(sentinel)")
        }
    }

    private struct SentinelWhereStoppedDeriver: WhereStoppedDeriverProtocol {
        let sentinel: String
        var idleSeconds: Int { 60 }
        func derive(
            in db: GRDB.Database,
            sinceMs: Int64,
            untilMs: Int64
        ) throws -> WhereStoppedOutput? {
            WhereStoppedOutput(
                excerpt: "Stopped at: \(sentinel)",
                wipSignals: WipSignals(commitWip: false, ciFailing: false, midEdit: false),
                anchorEventID: nil
            )
        }
    }

    private func sentinelMoat(
        decisionSentinel: String? = nil,
        openQuestionSentinel: String? = nil,
        blockerSentinel: String? = nil,
        whereStoppedSentinel: String? = nil
    ) -> DetectorMoat {
        DetectorMoat(
            decision: decisionSentinel.map { SentinelDecisionMoat(sentinel: $0) }
                ?? NoOpDecisionDetector(),
            openQuestion: openQuestionSentinel.map { SentinelOpenQuestionMoat(sentinel: $0) }
                ?? NoOpOpenQuestionDetector(),
            blockerPattern: blockerSentinel.map { SentinelBlockerPatternMoat(sentinel: $0) }
                ?? NoOpBlockerPatternDetector(),
            linearStuck: NoOpLinearStuckScanner(),
            whereStopped: whereStoppedSentinel.map { SentinelWhereStoppedDeriver(sentinel: $0) }
                ?? NoOpWhereStoppedDeriver(),
            absence: ExactMatchAbsence()
        )
    }

    // MARK: - D3 detector privacy regression

    func testDecisionExcerpt_DoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-DECISION-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "We DECIDE: \(sentinel)"
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 3]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        // Pipeline runs SEPARATELY from the write helper (Commit 9 architecture).
        try DetectorPipeline.runIncremental(
            moat: sentinelMoat(decisionSentinel: sentinel), nowMs: nowMs, in: db
        )

        // Positive: sentinel landed in detector table (otherwise negative is vacuous).
        let inDecisions = try db.readSQL { rawDB in
            try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM decisions WHERE reasoning_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inDecisions, "Sanity: sentinel should be in decisions before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(sentinel),
                           "Decision reasoning_excerpt MUST NOT leak into presence_state.state_json")
        }
    }

    func testOpenQuestionExcerpt_DoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-OPENQ-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "Open question: \(sentinel)?",
                "linked_linear_id": "LEAF-42"
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 1]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try DetectorPipeline.runIncremental(
            moat: sentinelMoat(openQuestionSentinel: sentinel), nowMs: nowMs, in: db
        )

        let inQuestions = try db.readSQL { rawDB in
            try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM open_questions WHERE question_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inQuestions, "Sanity: sentinel should be in open_questions before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(sentinel),
                           "OpenQuestion question_excerpt MUST NOT leak into presence_state.state_json")
        }
    }

    func testBlockerExcerpt_DoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-BLOCKER-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "We are BLOCKED: \(sentinel)",
                "linked_linear_id": "LEAF-7"
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 5]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try DetectorPipeline.runIncremental(
            moat: sentinelMoat(blockerSentinel: sentinel), nowMs: nowMs, in: db
        )

        let inBlockers = try db.readSQL { rawDB in
            try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM blockers WHERE blocker_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inBlockers, "Sanity: sentinel should be in blockers before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(sentinel),
                           "Blocker blocker_excerpt MUST NOT leak into presence_state.state_json")
        }
    }

    func testWhereStoppedExcerpt_DoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-WHERESTOPPED-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Write any presence-bearing event so presence_state row exists for the
        // negative assertion. WhereStopped does not depend on event payload —
        // the deriver is invoked unconditionally by runScheduled.
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.apple.dt.Xcode",
            payload: ["event_kind": "focus_session_started"]
        )
        let presenceState: [String: Any] = ["status": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        // runScheduled invokes WhereStoppedDeriver — separate from runIncremental.
        try DetectorPipeline.runScheduled(
            moat: sentinelMoat(whereStoppedSentinel: sentinel), nowMs: nowMs, in: db
        )

        let inLog = try db.readSQL { rawDB in
            try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM where_stopped_log WHERE excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inLog, "Sanity: sentinel should be in where_stopped_log before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(sentinel),
                           "WhereStopped excerpt MUST NOT leak into presence_state.state_json")
        }
    }

    func testCrossTableIsolation_AllDetectorTablesClean() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        // Distinct sentinel per detector — single body triggers all three
        // per-event detectors via substring matching; runScheduled handles
        // WhereStopped separately.
        let decisionSentinel = "ZZZZ-XTABLE-DECISION-ZZZZ"
        let openQSentinel = "ZZZZ-XTABLE-OPENQ-ZZZZ"
        let blockerSentinel = "ZZZZ-XTABLE-BLOCKER-ZZZZ"
        let whereStoppedSentinel = "ZZZZ-XTABLE-WHERESTOPPED-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // One event whose body contains all three per-event sentinels →
        // all three detectors fire on the same body within one pipeline pass.
        let body = "DECIDE: \(decisionSentinel) | QUESTION: \(openQSentinel) | BLOCKED: \(blockerSentinel)"
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: body,
                "linked_linear_id": "LEAF-100"
            ]
        )
        let presenceState: [String: Any] = ["assigned_count": 2]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        let moat = sentinelMoat(
            decisionSentinel: decisionSentinel,
            openQuestionSentinel: openQSentinel,
            blockerSentinel: blockerSentinel,
            whereStoppedSentinel: whereStoppedSentinel
        )
        try DetectorPipeline.runIncremental(moat: moat, nowMs: nowMs, in: db)
        try DetectorPipeline.runScheduled(moat: moat, nowMs: nowMs, in: db)

        // Positive sanity: each sentinel landed in its own detector table.
        try db.readSQL { rawDB in
            let inDecisions = try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM decisions WHERE reasoning_excerpt LIKE '%' || ? || '%'",
                arguments: [decisionSentinel]) ?? false
            XCTAssertTrue(inDecisions, "Sanity: decisions populated")

            let inOpenQ = try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM open_questions WHERE question_excerpt LIKE '%' || ? || '%'",
                arguments: [openQSentinel]) ?? false
            XCTAssertTrue(inOpenQ, "Sanity: open_questions populated")

            let inBlockers = try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM blockers WHERE blocker_excerpt LIKE '%' || ? || '%'",
                arguments: [blockerSentinel]) ?? false
            XCTAssertTrue(inBlockers, "Sanity: blockers populated")

            let inWhereStopped = try Bool.fetchOne(rawDB, sql:
                "SELECT count(*)>0 FROM where_stopped_log WHERE excerpt LIKE '%' || ? || '%'",
                arguments: [whereStoppedSentinel]) ?? false
            XCTAssertTrue(inWhereStopped, "Sanity: where_stopped_log populated")
        }

        // Negative invariant: NONE of the sentinels appear in presence_state.
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(stateJSON.contains(decisionSentinel),
                           "Decision sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(stateJSON.contains(openQSentinel),
                           "OpenQuestion sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(stateJSON.contains(blockerSentinel),
                           "Blocker sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(stateJSON.contains(whereStoppedSentinel),
                           "WhereStopped sentinel must not appear in presence_state.state_json")
        }
    }

    // MARK: - Track 3 D1 — Linear deep sweep privacy regression
    //
    // D1 adds new Linear event_kinds (notifications, reactions, relations,
    // triage). None of these reach `presence_state` directly — the existing
    // hot-tier composite writer carries only structured presence counters.
    // These walkbacks assert that even when a D1 event lands in the events
    // table, its body / metadata fields never appear in
    // `presence_state.state_json` (the relay-broadcast surface). Uses the
    // inline `writeEventsOffsetAndPresence` seeding pattern matching the
    // existing tests above — simpler than spinning up LinearCollector and
    // independent of collector boot semantics.

    func testD1NotificationTitleDoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Seed presence_state.linear with structured-only state.
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_notification_received",
                "notification_id": "n1",
                "notification_kind": "issueAssignedToYou",
                "notification_title": "Alice mentioned you in LEAF-42 rebuild_oauth",
                "body": "Alice mentioned you in LEAF-42 rebuild_oauth"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("rebuild_oauth"),
                "D1 notification title MUST NOT leak into presence_state.state_json")
            XCTAssertFalse(stateJSON.contains("Alice mentioned"),
                "D1 notification title prefix MUST NOT leak")
        }
    }

    func testD1ReactionEmojiDoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_comment_reaction_added",
                "comment_id": "c1",
                "issue_id": "i1",
                "issue_identifier": "LEAF-7",
                "emoji": "rocket-unique-marker",
                "reacted_at_ms": "100"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("rocket-unique-marker"),
                "Reaction emoji MUST NOT leak into presence_state.state_json")
        }
    }

    // MARK: - Track 3 D2 — GitHub deep sweep privacy regression
    //
    // D2 adds 31 new GitHub event_kinds across hot/warm/cold tiers (gists,
    // releases, deployments, ProjectV2 fields, codespaces, repo invitations,
    // security alerts, audit log, issue reactions). None of these reach
    // `presence_state` directly — the existing composite writer carries only
    // structured presence counters. These walkbacks assert that even when a
    // D2 event lands in the events table, its body / metadata fields never
    // appear in `presence_state.state_json` (the relay-broadcast surface).
    // Mirrors the D1 inline `writeEventsOffsetAndPresence` seeding pattern.
    //
    // These are regression sentinels — they pass immediately because no
    // D2 code currently writes bodies into `presence_state`. The tests
    // prevent future leakage during refactors.

    func testRelayDoesNotLeakGistDescription() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.gistCreated.rawValue,
                Schema.EventPayloadKeys.gistId: "g1",
                Schema.EventPayloadKeys.gistDescription: "BODY_SENTINEL_GIST",
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_GIST"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_GIST"),
                "Gist description body MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakReleaseBody() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.releasePublished.rawValue,
                "repo": "o/r",
                "tag_name": "v1.2.3",
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_RELEASE changelog with details"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_RELEASE"),
                "Release body MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakDeploymentDescription() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.deploymentCreated.rawValue,
                "repo": "o/r",
                "environment": "production",
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_DEPLOY description text"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_DEPLOY"),
                "Deployment description MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakProjectV2FieldValues() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.projectFieldUpdated.rawValue,
                "project_id": "p1",
                "field_name": "Status",
                Schema.EventPayloadKeys.projectV2NewValue: "BODY_SENTINEL_PROJECTV2_VALUE"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_PROJECTV2_VALUE"),
                "ProjectV2 field value MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakCodespaceName() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.codespaceStarted.rawValue,
                Schema.EventPayloadKeys.codespaceName: "BODY_SENTINEL_CODESPACE_NAME",
                "repo": "o/r"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_CODESPACE_NAME"),
                "Codespace name MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakRepoInvitationFromLogin() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.repoInvitationReceived.rawValue,
                "invitation_id": "inv1",
                "repo": "o/r",
                Schema.EventPayloadKeys.repoInvitationFromLogin: "BODY_SENTINEL_INVITER_LOGIN"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_INVITER_LOGIN"),
                "Repo invitation from-login MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakSecurityAlertRule() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.secretAlertObserved.rawValue,
                "repo": "o/r",
                "alert_id": "a1",
                Schema.EventPayloadKeys.alertRule: "BODY_SENTINEL_ALERT_RULE"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_ALERT_RULE"),
                "Security alert rule MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakAuditAction() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.auditActionObserved.rawValue,
                "org": "o",
                Schema.EventPayloadKeys.auditAction: "BODY_SENTINEL_AUDIT_ACTION"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_AUDIT_ACTION"),
                "Audit action string MUST NOT leak into presence_state.state_json")
        }
    }

    func testRelayDoesNotLeakIssueReactionEmoji() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": GitHubEventKindKey.issueReactionReceived.rawValue,
                "repo": "o/r",
                "issue_number": "42",
                Schema.EventPayloadKeys.reactionEmoji: "BODY_SENTINEL_REACTION_EMOJI",
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_REACTION_EMOJI"
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("BODY_SENTINEL_REACTION_EMOJI"),
                "Issue reaction emoji MUST NOT leak into presence_state.state_json")
        }
    }

    func testD1RelationAndTriageMetadataDoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writeEventsOffsetAndPresence(
            [],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:test", nowMs: nowMs),
            presence: (provider: .linear, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )
        let rel = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_relation_added",
                "relation_id": "rel-1",
                "from_issue_identifier": "LEAF-1",
                "to_issue_identifier": "LEAF-99-unique-marker",
                "relation_kind": "blocks",
                "started_at_ms": "100"
            ]
        )
        let triage = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_triage_item_resolved",
                "issue_id": "i1",
                "issue_identifier": "LEAF-77",
                "team_id": "t1",
                "to_state_name": "Done-canary-marker",
                "to_state_type": "completed",
                "resolution_kind": "completed",
                "completed_at_ms": "100"
            ]
        )
        try db.write(rel)
        try db.write(triage)

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains("LEAF-99-unique-marker"),
                "D1 relation target_identifier MUST NOT leak")
            XCTAssertFalse(stateJSON.contains("Done-canary-marker"),
                "D1 triage to_state_name MUST NOT leak")
        }
    }

    // MARK: - Track 3 D3 — Slack deep sweep privacy regression
    //
    // D3 adds 21 new Slack event_kinds across hot/warm/cold tiers. Only 4 are
    // body-bearing per ADR-010 §6 (canvas + bookmark titles — user-named
    // structured resources). Body-bearing tests assert the sentinel reaches
    // FTS (sanity — pipeline ran) but does NOT leak into `presence_state`.
    // Dropped-text tests assert sentinels injected into payload fields that
    // are NOT body-indexed by design (pin itemRef / reminder id / scheduled
    // message id / custom emoji name / usergroup membership IDs) reach neither
    // FTS nor presence_state. The dropped-text sentinels guard against
    // accidental leakage if a future refactor mirrors a metadata field into
    // `body` or `state_json`.

    // MARK: Body-bearing positive (canvas + bookmark)

    func testCanvasTitleSentinelReachesFTSButNotPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-CANVAS-TITLE-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackCanvasCreated.rawValue,
                Schema.EventPayloadKeys.canvasId: "c1",
                Schema.EventPayloadKeys.bookmarkTitle: sentinel,
                Schema.EventPayloadKeys.body: sentinel
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        // Sanity: canvas title indexed in FTS via the slack_canvas_title body_kind.
        let ftsCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                arguments: [Schema.BodyKinds.slackCanvasTitle]) ?? 0
        }
        XCTAssertEqual(ftsCount, 1,
            "Sanity: canvas title should be indexed under slack_canvas_title before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Slack canvas title MUST NOT leak into presence_state.state_json")
        }
    }

    func testBookmarkTitleSentinelReachesFTSButNotPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-BOOKMARK-TITLE-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackBookmarkAdded.rawValue,
                Schema.EventPayloadKeys.channelId: "C1",
                Schema.EventPayloadKeys.bookmarkId: "b1",
                Schema.EventPayloadKeys.bookmarkTitle: sentinel,
                Schema.EventPayloadKeys.bookmarkURL: "https://example.com",
                Schema.EventPayloadKeys.body: sentinel
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        let ftsCount = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                arguments: [Schema.BodyKinds.slackBookmarkTitle]) ?? 0
        }
        XCTAssertEqual(ftsCount, 1,
            "Sanity: bookmark title should be indexed under slack_bookmark_title before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Slack bookmark title MUST NOT leak into presence_state.state_json")
        }
    }

    // MARK: Dropped-text negative (pin / reminder / scheduled / emoji / usergroup)
    //
    // For each test the sentinel is injected into a payload field on a Slack
    // event_kind whose body_kind dispatch in `EventsFullTextStore` is
    // intentionally absent. Assertions:
    //  (1) sentinel did NOT reach `events_fts_meta` (no body_kind row carries
    //      the sentinel via its body column);
    //  (2) sentinel did NOT reach `presence_state.state_json`.
    // The events_fts_meta count check is sufficient because FTS rows are
    // written only via `EventsFullTextStore.indexEvent`, and that store skips
    // events whose event_kind has no `topLevelBodyKind` dispatch entry AND
    // whose payload lacks the JSON-array fan-out keys (commentBodiesJson /
    // threadRepliesJson / messagesJson). None of the five negative event_kinds
    // ship any of those.

    func testPinMessageBodyNeverReachesFTSOrPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-PIN-MESSAGE-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Sentinel deliberately placed in itemRef — a captured metadata field
        // — to prove that even captured-but-non-body-bearing fields cannot
        // surface into FTS or presence_state.
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackPinAdded.rawValue,
                Schema.EventPayloadKeys.channelId: "C1",
                Schema.EventPayloadKeys.itemRef: sentinel,
                Schema.EventPayloadKeys.pinnedAtMs: "100"
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let ftsHits = try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(ftsHits, 0,
                "Pin events MUST NOT produce FTS rows (no body-kind dispatch entry)")
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Pin itemRef sentinel MUST NOT leak into presence_state.state_json")
        }
    }

    func testReminderTextNeverReachesFTSOrPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-REMINDER-TEXT-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackReminderCreated.rawValue,
                Schema.EventPayloadKeys.reminderId: sentinel,
                Schema.EventPayloadKeys.dueTs: "200"
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let ftsHits = try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(ftsHits, 0,
                "Reminder events MUST NOT produce FTS rows (reminder.text is dropped at provider boundary)")
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Reminder id sentinel MUST NOT leak into presence_state.state_json")
        }
    }

    func testScheduledMessageTextNeverReachesFTSOrPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-SCHEDULED-MSG-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackMessageScheduled.rawValue,
                Schema.EventPayloadKeys.scheduledMessageId: sentinel,
                Schema.EventPayloadKeys.scheduledFor: "200",
                Schema.EventPayloadKeys.channelId: "C1"
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let ftsHits = try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(ftsHits, 0,
                "Scheduled-message events MUST NOT produce FTS rows (scheduled body is dropped at provider boundary)")
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Scheduled message id sentinel MUST NOT leak into presence_state.state_json")
        }
    }

    func testCustomEmojiURLNeverReachesFTSOrPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-EMOJI-URL-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Cold tier captures emoji_name only — image URL is dropped at the
        // provider boundary. Inject sentinel via emoji_name to confirm even
        // captured fields do not surface in FTS or presence_state.
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackCustomEmojiAdded.rawValue,
                Schema.EventPayloadKeys.emojiName: sentinel,
                Schema.EventPayloadKeys.workspaceId: "W1"
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let ftsHits = try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(ftsHits, 0,
                "Custom emoji events MUST NOT produce FTS rows (image URL is dropped at provider boundary)")
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Custom emoji name sentinel MUST NOT leak into presence_state.state_json")
        }
    }

    func testUsergroupProfileDataNeverReachesFTSOrPresence() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "ZZZZ-USERGROUP-PROFILE-SENTINEL-ZZZZ"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Cold tier captures only added/removed user IDs — never user profile
        // (display name / email / avatar). Inject sentinel into the captured
        // ID array to confirm even captured fields cannot surface.
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackUsergroupMembershipChanged.rawValue,
                Schema.EventPayloadKeys.groupId: "G1",
                Schema.EventPayloadKeys.addedUserIdsJson: #"[""# + sentinel + #""]"#,
                Schema.EventPayloadKeys.removedUserIdsJson: "[]",
                Schema.EventPayloadKeys.workspaceId: "W1"
            ]
        )
        let presenceState: [String: Any] = ["presence": "active"]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.slackPolling, sourceID: "slack:test", nowMs: nowMs),
            presence: (provider: .slack, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let ftsHits = try Int.fetchOne(rawDB, sql:
                "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(ftsHits, 0,
                "Usergroup membership events MUST NOT produce FTS rows (no body-kind dispatch entry)")
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(sentinel),
                "Usergroup membership user-ID sentinel MUST NOT leak into presence_state.state_json")
        }
    }

    // MARK: - Phase Track-4 S1 — Architecture catch-up walkbacks

    /// Adversarial payload with fake meeting title MUST NOT reach
    /// `presence_state.state_json`. Collectors are designed to never include
    /// title (compile-time via MeetingObservation), but this defence layer
    /// catches a future regression where a collector accidentally adds the
    /// field.
    func testMeetingStateEventDoesNotLeakIntoPresenceState_S1() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let titleMarker = "SECRET-MEETING-TITLE-MARKER-S1"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "meeting_state_entered",
                "state": "in_meeting",
                "title": titleMarker
            ]
        )
        let presenceState: [String: Any] = ["dummy": true]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: "calendar", sourceID: "calendar:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(titleMarker),
                "Meeting title MUST NOT appear in presence_state.state_json")
        }
    }

    /// Same shape for focus_mode_* events — fake mode name MUST NOT leak.
    func testFocusModeEventDoesNotLeakIntoPresenceState_S1() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let modeNameMarker = "SECRET-FOCUS-MODE-NAME-MARKER-S1"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "focus_mode_enabled",
                "state": "focused",
                "mode_name": modeNameMarker
            ]
        )
        let presenceState: [String: Any] = ["dummy": true]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: "focus", sourceID: "focus:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(modeNameMarker),
                "Focus mode name MUST NOT appear in presence_state.state_json")
        }
    }

    /// Same shape for system_locked event — adversarial host marker MUST NOT leak.
    func testSystemStateEventDoesNotLeakIntoPresenceState_S1() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let hostMarker = "SECRET-HOSTNAME-MARKER-S1"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "system_locked",
                "host": hostMarker
            ]
        )
        let presenceState: [String: Any] = ["dummy": true]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: "system_state", sourceID: "system_state:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(hostMarker),
                "System hostname MUST NOT appear in presence_state.state_json")
        }
    }

    /// Same shape for space_switched event — fake space identifier MUST NOT leak.
    func testSpaceSwitchedEventDoesNotLeakIntoPresenceState_S1() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let spaceIDMarker = "SECRET-SPACE-IDENTIFIER-MARKER-S1"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "space_switched",
                "space_id": spaceIDMarker
            ]
        )
        let presenceState: [String: Any] = ["dummy": true]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: "spaces", sourceID: "spaces:test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.contains(spaceIDMarker),
                "Space identifier MUST NOT appear in presence_state.state_json")
        }
    }

    // MARK: - Phase Track-4 S2 — AppleScript surface walkbacks

    /// Helper: assert that an adversarial payload field never reaches
    /// `presence_state.state_json` after `writeEventsOffsetAndPresence`.
    /// Each S2 event_kind below gets a dedicated walkback so a regression
    /// at the per-adapter layer would surface a clear failure.
    private func assertS2DoesNotLeak(
        eventKind: String,
        extraPayload: [String: String],
        markers: [String],
        collectorID: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var payload: [String: String] = ["event_kind": eventKind]
        for (k, v) in extraPayload { payload[k] = v }
        let event = RawEvent(
            timestamp: Date(),
            signalType: .attention,
            bundleID: nil,
            payload: payload
        )
        let presenceState: [String: Any] = ["dummy": true]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: collectorID, sourceID: "\(collectorID):test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON = (try Row.fetchOne(rawDB, sql:
                "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?) ?? ""
            for m in markers {
                XCTAssertFalse(stateJSON.contains(m),
                    "Marker '\(m)' MUST NOT appear in presence_state.state_json for \(eventKind)",
                    file: file, line: line)
            }
        }
    }

    func testRelayDoesNotLeakXcodeActiveDocBody_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "xcode_active_doc_changed",
            extraPayload: ["doc_path": "/p", "body": "SECRET-XCODE-DOC-BODY-S2"],
            markers: ["SECRET-XCODE-DOC-BODY-S2"],
            collectorID: "applescript_xcode"
        )
    }

    func testRelayDoesNotLeakXcodeBuildLogOutput_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "xcode_build_state_changed",
            extraPayload: ["build_state": "failed", "log_output": "SECRET-XCODE-BUILD-LOG-S2"],
            markers: ["SECRET-XCODE-BUILD-LOG-S2"],
            collectorID: "applescript_xcode"
        )
    }

    func testRelayDoesNotLeakJetBrainsDocContent_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "jetbrains_active_doc_changed",
            extraPayload: [
                "ide_bundle_id": "com.jetbrains.pycharm",
                "doc_path": "/p.py",
                "content": "SECRET-JETBRAINS-CONTENT-S2"
            ],
            markers: ["SECRET-JETBRAINS-CONTENT-S2"],
            collectorID: "applescript_jetbrains"
        )
    }

    func testRelayDoesNotLeakMusicLyrics_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "music_track_changed",
            extraPayload: ["track": "T", "artist": "A", "lyrics": "SECRET-MUSIC-LYRICS-S2"],
            markers: ["SECRET-MUSIC-LYRICS-S2"],
            collectorID: "applescript_music"
        )
    }

    func testRelayDoesNotLeakSpotifyLyrics_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "spotify_track_changed",
            extraPayload: ["track": "T", "artist": "A", "lyrics": "SECRET-SPOTIFY-LYRICS-S2"],
            markers: ["SECRET-SPOTIFY-LYRICS-S2"],
            collectorID: "applescript_spotify"
        )
    }

    func testRelayDoesNotLeakNotesBody_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "notes_active_title_changed",
            extraPayload: [
                "note_title": "T",
                "body": "SECRET-NOTE-BODY-MARKER-S2",
                "plaintext": "SECRET-NOTE-PLAINTEXT-MARKER-S2"
            ],
            markers: ["SECRET-NOTE-BODY-MARKER-S2", "SECRET-NOTE-PLAINTEXT-MARKER-S2"],
            collectorID: "applescript_notes"
        )
    }

    func testRelayDoesNotLeakReminderTitle_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "reminder_completed",
            extraPayload: [
                "list_name": "Inbox",
                "completed_count_delta": "3",
                "reminder_title": "SECRET-REMINDER-TITLE-S2",
                "notes": "SECRET-REMINDER-NOTES-S2"
            ],
            markers: ["SECRET-REMINDER-TITLE-S2", "SECRET-REMINDER-NOTES-S2"],
            collectorID: "applescript_reminders"
        )
    }

    func testRelayDoesNotLeakCalendarEventTitle_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "calendar_app_view_changed",
            extraPayload: [
                "view_mode": "week",
                "visible_date_range_days": "7",
                "event_title": "SECRET-EVENT-TITLE-S2",
                "attendees": "SECRET-ATTENDEES-LIST-S2"
            ],
            markers: ["SECRET-EVENT-TITLE-S2", "SECRET-ATTENDEES-LIST-S2"],
            collectorID: "applescript_calendar"
        )
    }

    func testRelayDoesNotLeakMailBodyOrSubject_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "mail_active_mailbox_changed",
            extraPayload: [
                "mailbox_name": "Inbox",
                "body": "SECRET-MAIL-BODY-S2",
                "subject": "SECRET-MAIL-SUBJECT-S2",
                "from": "SECRET-MAIL-FROM-S2"
            ],
            markers: ["SECRET-MAIL-BODY-S2", "SECRET-MAIL-SUBJECT-S2", "SECRET-MAIL-FROM-S2"],
            collectorID: "applescript_mail"
        )
    }

    func testRelayDoesNotLeakZoomAttendees_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "zoom_meeting_state_changed",
            extraPayload: [
                "meeting_state": "in_meeting",
                "attendees": "SECRET-ZOOM-ATTENDEES-LIST-S2",
                "password": "SECRET-ZOOM-PASSWORD-S2"
            ],
            markers: ["SECRET-ZOOM-ATTENDEES-LIST-S2", "SECRET-ZOOM-PASSWORD-S2"],
            collectorID: "applescript_zoom"
        )
    }

    func testRelayDoesNotLeakZoomTopic_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "zoom_meeting_name_observed",
            extraPayload: [
                "meeting_topic": "T",
                "password": "SECRET-ZOOM-NAME-PASSWORD-S2",
                "chat_history": "SECRET-ZOOM-CHAT-S2"
            ],
            markers: ["SECRET-ZOOM-NAME-PASSWORD-S2", "SECRET-ZOOM-CHAT-S2"],
            collectorID: "applescript_zoom"
        )
    }

    func testRelayDoesNotLeakSafariCookiesOrSource_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "safari_tabs_changed",
            extraPayload: [
                "tabs": "[]",
                "cookies": "SECRET-SAFARI-COOKIES-S2",
                "source": "SECRET-SAFARI-SOURCE-S2",
                "history": "SECRET-SAFARI-HISTORY-S2"
            ],
            markers: ["SECRET-SAFARI-COOKIES-S2", "SECRET-SAFARI-SOURCE-S2", "SECRET-SAFARI-HISTORY-S2"],
            collectorID: "applescript_safari"
        )
    }

    func testRelayDoesNotLeakChromeCookiesOrSource_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "chrome_tabs_changed",
            extraPayload: [
                "tabs": "[]",
                "cookies": "SECRET-CHROME-COOKIES-S2",
                "source": "SECRET-CHROME-SOURCE-S2"
            ],
            markers: ["SECRET-CHROME-COOKIES-S2", "SECRET-CHROME-SOURCE-S2"],
            collectorID: "applescript_chrome"
        )
    }

    func testRelayDoesNotLeakArcCookiesOrSource_S2() throws {
        try assertS2DoesNotLeak(
            eventKind: "arc_tabs_changed",
            extraPayload: [
                "tabs": "[]",
                "cookies": "SECRET-ARC-COOKIES-S2",
                "source": "SECRET-ARC-SOURCE-S2"
            ],
            markers: ["SECRET-ARC-COOKIES-S2", "SECRET-ARC-SOURCE-S2"],
            collectorID: "applescript_arc"
        )
    }

    // MARK: - Phase Track-6 P3 — browsers deep walkbacks (8 sentinel + 2 bypass)

    func testRelayDoesNotLeakSafariTabNavigated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "safari_tab_navigated",
            extraPayload: [
                "tab_key": "i3",
                "previous_url": "github.com",
                "current_url": "github.com/foo",
                "cookies": "SECRET-SAFARI-NAV-COOKIES-P3",
                "source": "SECRET-SAFARI-NAV-SOURCE-P3",
                "history": "SECRET-SAFARI-NAV-HISTORY-P3",
                "form_data": "SECRET-SAFARI-NAV-FORM-P3",
                "autofill": "SECRET-SAFARI-NAV-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-SAFARI-NAV-COOKIES-P3",
                "SECRET-SAFARI-NAV-SOURCE-P3",
                "SECRET-SAFARI-NAV-HISTORY-P3",
                "SECRET-SAFARI-NAV-FORM-P3",
                "SECRET-SAFARI-NAV-AUTOFILL-P3"
            ],
            collectorID: "applescript_safari"
        )
    }

    func testRelayDoesNotLeakChromeTabNavigated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "chrome_tab_navigated",
            extraPayload: [
                "tab_key": "1",
                "previous_url": "github.com",
                "current_url": "linear.app",
                "cookies": "SECRET-CHROME-NAV-COOKIES-P3",
                "source": "SECRET-CHROME-NAV-SOURCE-P3",
                "history": "SECRET-CHROME-NAV-HISTORY-P3",
                "form_data": "SECRET-CHROME-NAV-FORM-P3",
                "autofill": "SECRET-CHROME-NAV-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-CHROME-NAV-COOKIES-P3",
                "SECRET-CHROME-NAV-SOURCE-P3",
                "SECRET-CHROME-NAV-HISTORY-P3",
                "SECRET-CHROME-NAV-FORM-P3",
                "SECRET-CHROME-NAV-AUTOFILL-P3"
            ],
            collectorID: "applescript_chrome"
        )
    }

    func testRelayDoesNotLeakArcTabNavigated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "arc_tab_navigated",
            extraPayload: [
                "tab_key": "arc-1",
                "previous_url": "github.com",
                "current_url": "notion.so",
                "cookies": "SECRET-ARC-NAV-COOKIES-P3",
                "source": "SECRET-ARC-NAV-SOURCE-P3",
                "history": "SECRET-ARC-NAV-HISTORY-P3",
                "form_data": "SECRET-ARC-NAV-FORM-P3",
                "autofill": "SECRET-ARC-NAV-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-ARC-NAV-COOKIES-P3",
                "SECRET-ARC-NAV-SOURCE-P3",
                "SECRET-ARC-NAV-HISTORY-P3",
                "SECRET-ARC-NAV-FORM-P3",
                "SECRET-ARC-NAV-AUTOFILL-P3"
            ],
            collectorID: "applescript_arc"
        )
    }

    func testRelayDoesNotLeakSafariTabActivated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "safari_tab_activated",
            extraPayload: [
                "current_tab_key": "i2",
                "previous_tab_key": "i1",
                "current_url": "github.com",
                "cookies": "SECRET-SAFARI-ACT-COOKIES-P3",
                "source": "SECRET-SAFARI-ACT-SOURCE-P3",
                "history": "SECRET-SAFARI-ACT-HISTORY-P3",
                "form_data": "SECRET-SAFARI-ACT-FORM-P3",
                "autofill": "SECRET-SAFARI-ACT-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-SAFARI-ACT-COOKIES-P3",
                "SECRET-SAFARI-ACT-SOURCE-P3",
                "SECRET-SAFARI-ACT-HISTORY-P3",
                "SECRET-SAFARI-ACT-FORM-P3",
                "SECRET-SAFARI-ACT-AUTOFILL-P3"
            ],
            collectorID: "applescript_safari"
        )
    }

    func testRelayDoesNotLeakChromeTabActivated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "chrome_tab_activated",
            extraPayload: [
                "current_tab_key": "2",
                "previous_tab_key": "1",
                "current_url": "linear.app",
                "cookies": "SECRET-CHROME-ACT-COOKIES-P3",
                "source": "SECRET-CHROME-ACT-SOURCE-P3",
                "history": "SECRET-CHROME-ACT-HISTORY-P3",
                "form_data": "SECRET-CHROME-ACT-FORM-P3",
                "autofill": "SECRET-CHROME-ACT-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-CHROME-ACT-COOKIES-P3",
                "SECRET-CHROME-ACT-SOURCE-P3",
                "SECRET-CHROME-ACT-HISTORY-P3",
                "SECRET-CHROME-ACT-FORM-P3",
                "SECRET-CHROME-ACT-AUTOFILL-P3"
            ],
            collectorID: "applescript_chrome"
        )
    }

    func testRelayDoesNotLeakArcTabActivated_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "arc_tab_activated",
            extraPayload: [
                "current_tab_key": "arc-2",
                "previous_tab_key": "arc-1",
                "current_url": "notion.so",
                "cookies": "SECRET-ARC-ACT-COOKIES-P3",
                "source": "SECRET-ARC-ACT-SOURCE-P3",
                "history": "SECRET-ARC-ACT-HISTORY-P3",
                "form_data": "SECRET-ARC-ACT-FORM-P3",
                "autofill": "SECRET-ARC-ACT-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-ARC-ACT-COOKIES-P3",
                "SECRET-ARC-ACT-SOURCE-P3",
                "SECRET-ARC-ACT-HISTORY-P3",
                "SECRET-ARC-ACT-FORM-P3",
                "SECRET-ARC-ACT-AUTOFILL-P3"
            ],
            collectorID: "applescript_arc"
        )
    }

    func testRelayDoesNotLeakChromeBookmarkChanged_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "chrome_bookmark_changed",
            extraPayload: [
                "total_count": "143",
                "delta": "1",
                "profile_label": "Default",
                "cookies": "SECRET-CHROME-BM-COOKIES-P3",
                "source": "SECRET-CHROME-BM-SOURCE-P3",
                "history": "SECRET-CHROME-BM-HISTORY-P3",
                "form_data": "SECRET-CHROME-BM-FORM-P3",
                "autofill": "SECRET-CHROME-BM-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-CHROME-BM-COOKIES-P3",
                "SECRET-CHROME-BM-SOURCE-P3",
                "SECRET-CHROME-BM-HISTORY-P3",
                "SECRET-CHROME-BM-FORM-P3",
                "SECRET-CHROME-BM-AUTOFILL-P3"
            ],
            collectorID: "fsevents_browser_bookmarks"
        )
    }

    func testRelayDoesNotLeakSafariBookmarkChanged_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "safari_bookmark_changed",
            extraPayload: [
                "total_count": "11",
                "delta": "-1",
                "profile_label": "",
                "cookies": "SECRET-SAFARI-BM-COOKIES-P3",
                "source": "SECRET-SAFARI-BM-SOURCE-P3",
                "history": "SECRET-SAFARI-BM-HISTORY-P3",
                "form_data": "SECRET-SAFARI-BM-FORM-P3",
                "autofill": "SECRET-SAFARI-BM-AUTOFILL-P3"
            ],
            markers: [
                "SECRET-SAFARI-BM-COOKIES-P3",
                "SECRET-SAFARI-BM-SOURCE-P3",
                "SECRET-SAFARI-BM-HISTORY-P3",
                "SECRET-SAFARI-BM-FORM-P3",
                "SECRET-SAFARI-BM-AUTOFILL-P3"
            ],
            collectorID: "fsevents_browser_bookmarks"
        )
    }

    func testAllowListFilterNotBypassedViaCraftedPayload_P3() throws {
        // Sanity: inject a domain string into title (filter-irrelevant field) —
        // existing assertS2DoesNotLeak walks all payload values for markers,
        // so any leak would surface even via crafted fields.
        try assertS2DoesNotLeak(
            eventKind: "safari_tab_navigated",
            extraPayload: [
                "tab_key": "i1",
                "previous_url": "github.com",
                "current_url": "linear.app",
                "title": "SECRET-DOMAIN-IN-TITLE-P3"
            ],
            markers: ["SECRET-DOMAIN-IN-TITLE-P3"],
            collectorID: "applescript_safari"
        )
    }

    func testRelayDoesNotLeakUnfilteredURLViaTitlePassthrough_P3() throws {
        try assertS2DoesNotLeak(
            eventKind: "chrome_tab_activated",
            extraPayload: [
                "current_tab_key": "1",
                "previous_tab_key": "2",
                "current_url": "linear.app/i/LEAF-SECRET-P3",
                "title": "Secret · LEAF-SECRET-P3"
            ],
            markers: ["LEAF-SECRET-P3"],
            collectorID: "applescript_chrome"
        )
    }

    // MARK: - Phase Track-4 S3 — system observers + intensity walkbacks (13)

    /// 13 walkbacks — one per new event_kind. Each smuggles content marker
    /// фейковым payload key (body / characters / pixels / etc) и assert'ит
    /// что marker не появляется в presence_state.state_json.

    func testRelayDoesNotLeakIntensitySnapshot_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "intensity_snapshot",
            extraPayload: [
                "keystroke_count": "50",
                "mouse_move_count": "100",
                "app_switch_count": "2",
                "foreground_app": "com.apple.dt.Xcode",
                "characters": "SECRET-KEYS-INTENSITY-S3",
                "body": "SECRET-INTENSITY-BODY-S3"
            ],
            markers: ["SECRET-KEYS-INTENSITY-S3", "SECRET-INTENSITY-BODY-S3"],
            collectorID: "cgevent_tap"
        )
    }

    func testRelayDoesNotLeakIntensityBucketDropped_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "intensity_bucket_dropped",
            extraPayload: [
                "state": "locked",
                "body": "SECRET-DROPPED-BUCKET-BODY-S3"
            ],
            markers: ["SECRET-DROPPED-BUCKET-BODY-S3"],
            collectorID: "cgevent_tap"
        )
    }

    func testRelayDoesNotLeakAudioRouteDeviceName_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "audio_route_changed",
            extraPayload: [
                "audio_route": "bluetooth",
                "device_name": "SECRET-AIRPODS-NAME-S3",
                "manufacturer": "SECRET-MANUFACTURER-S3"
            ],
            markers: ["SECRET-AIRPODS-NAME-S3", "SECRET-MANUFACTURER-S3"],
            collectorID: "audio_route"
        )
    }

    func testRelayDoesNotLeakMicInUseEntered_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "mic_in_use_entered",
            extraPayload: [
                "state": "mic_in_use",
                "audio_samples": "SECRET-MIC-SAMPLES-S3"
            ],
            markers: ["SECRET-MIC-SAMPLES-S3"],
            collectorID: "mic_in_use"
        )
    }

    func testRelayDoesNotLeakMicInUseExited_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "mic_in_use_exited",
            extraPayload: [
                "state": "mic_idle",
                "audio_samples": "SECRET-MIC-EXIT-S3"
            ],
            markers: ["SECRET-MIC-EXIT-S3"],
            collectorID: "mic_in_use"
        )
    }

    func testRelayDoesNotLeakDisplayConnected_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "display_connected",
            extraPayload: [
                "state": "display_connected",
                "screen_image": "SECRET-DISPLAY-PIXELS-S3"
            ],
            markers: ["SECRET-DISPLAY-PIXELS-S3"],
            collectorID: "display"
        )
    }

    func testRelayDoesNotLeakDisplayDisconnected_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "display_disconnected",
            extraPayload: [
                "state": "display_disconnected",
                "screen_image": "SECRET-DISCONNECT-PIXELS-S3"
            ],
            markers: ["SECRET-DISCONNECT-PIXELS-S3"],
            collectorID: "display"
        )
    }

    func testRelayDoesNotLeakVPNCredentials_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "vpn_state_changed",
            extraPayload: [
                "state": "connected",
                "server_address": "SECRET-VPN-SERVER-S3",
                "username": "SECRET-VPN-USER-S3"
            ],
            markers: ["SECRET-VPN-SERVER-S3", "SECRET-VPN-USER-S3"],
            collectorID: "vpn"
        )
    }

    func testRelayDoesNotLeakWiFiSSID_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "wifi_state_changed",
            extraPayload: [
                "state": "connected",
                "ssid": "SECRET-WIFI-SSID-S3",
                "bssid": "SECRET-WIFI-BSSID-S3"
            ],
            markers: ["SECRET-WIFI-SSID-S3", "SECRET-WIFI-BSSID-S3"],
            collectorID: "wifi"
        )
    }

    func testRelayDoesNotLeakClipboardContent_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "clipboard_event_count",
            extraPayload: [
                "count": "3",
                "clipboard_content": "SECRET-CLIPBOARD-TEXT-S3",
                "body": "SECRET-CLIPBOARD-BODY-S3"
            ],
            markers: ["SECRET-CLIPBOARD-TEXT-S3", "SECRET-CLIPBOARD-BODY-S3"],
            collectorID: "clipboard"
        )
    }

    func testRelayDoesNotLeakScreenshotBody_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "screenshot_taken",
            extraPayload: [
                "filename": "Screenshot 2026-05-13.png",
                "body": "SECRET-SCREENSHOT-BODY-S3",
                "image_data": "SECRET-SCREENSHOT-PIXELS-S3"
            ],
            markers: ["SECRET-SCREENSHOT-BODY-S3", "SECRET-SCREENSHOT-PIXELS-S3"],
            collectorID: "local_files"
        )
    }

    func testRelayDoesNotLeakDownloadBody_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "download_added",
            extraPayload: [
                "filename": "report.pdf",
                "body": "SECRET-DOWNLOAD-BODY-S3",
                "source_url": "SECRET-DOWNLOAD-URL-S3"
            ],
            markers: ["SECRET-DOWNLOAD-BODY-S3", "SECRET-DOWNLOAD-URL-S3"],
            collectorID: "local_files"
        )
    }

    func testRelayDoesNotLeakTrashContent_S3() throws {
        try assertS2DoesNotLeak(
            eventKind: "trash_changed",
            extraPayload: [
                "action": "added",
                "deleted_filename": "SECRET-TRASH-FILENAME-S3",
                "body": "SECRET-TRASH-BODY-S3"
            ],
            markers: ["SECRET-TRASH-FILENAME-S3", "SECRET-TRASH-BODY-S3"],
            collectorID: "local_files"
        )
    }
}
