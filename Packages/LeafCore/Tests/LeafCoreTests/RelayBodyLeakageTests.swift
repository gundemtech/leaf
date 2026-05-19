// Phase Track-1 D1 — privacy regression: bodies must never reach presence_state JSON.
// Acceptance gate per Track 1 contract §6 (bodies on-device only — relay never sees).
//
// Phase Track-1 D3 — extension: detector excerpts (decision / open_question /
// blocker / where_stopped) must also stay on-device. DetectorPipeline runs
// in a separate timer-driven invocation (see Commit 9), not embedded in the
// write helper, so the tests below call `runIncremental` / `runScheduled`
// explicitly after the write.

import GRDB
import XCTest

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
                Schema.EventPayloadKeys.body: bodyText,
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
            XCTAssertFalse(
                stateJSON.contains(bodyText),
                "Body string MUST NOT appear in presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains("\"body\""),
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
                Schema.EventPayloadKeys.additions: "50",
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
                Schema.EventPayloadKeys.messagesJson: messagesJSON,
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
                Schema.EventPayloadKeys.threadRepliesJson: threadReplies,
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
                Schema.EventPayloadKeys.body: "discusses LEAF-127",
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
            try Int.fetchOne(
                rawDB, sql: "SELECT COUNT(*) FROM event_links WHERE target_ref = ?",
                arguments: ["LEAF-127"]) ?? 0
        }
        XCTAssertEqual(linkCount, 1, "Sanity: link should exist before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains("LEAF-127"),
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
                Schema.EventPayloadKeys.body: bodyText,
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
            try Int.fetchOne(
                rawDB, sql: "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                arguments: [Schema.BodyKinds.linearDesc]) ?? 0
        }
        XCTAssertEqual(ftsCount, 1, "Sanity: body should be indexed before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(bodyText),
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
                Schema.EventPayloadKeys.deletions: "2",
            ]
        )

        // Presence carries only structured PR metrics — no body text, no link refs.
        let presenceState: [String: Any] = [
            "review_count": 1,
            "additions": 10,
            "deletions": 2,
        ]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.githubPolling, sourceID: "github:test", nowMs: nowMs),
            presence: (provider: .github, state: presenceState, derivedMode: nil),
            knownLinearPrefixes: ["LEAF"],
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            // Body text MUST NOT be in presence_state.
            XCTAssertFalse(
                stateJSON.contains("Adds support"),
                "PR body excerpt must not appear in presence_state")
            XCTAssertFalse(
                stateJSON.contains(prBody),
                "PR body must not appear in presence_state")
            // Link target_refs MUST NOT be in presence_state.
            XCTAssertFalse(
                stateJSON.contains("LEAF-450"),
                "Linear ID target_ref must not appear in presence_state")
            XCTAssertFalse(
                stateJSON.contains("o/r/pull/9"),
                "PR URL target_ref must not appear in presence_state")
            XCTAssertFalse(
                stateJSON.contains("alice"),
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
            return DecisionHit(
                topicKeywords: ["sentinel"],
                reasoningExcerpt: "Decision: \(sentinel)",
                confidence: 0.9)
        }
    }

    private struct SentinelOpenQuestionMoat: OpenQuestionDetectorProtocol {
        let sentinel: String
        func detect(body: String, kind: BodyKind) -> OpenQuestionHit? {
            guard body.contains(sentinel) else { return nil }
            return OpenQuestionHit(
                questionExcerpt: "Question: \(sentinel)",
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
                Schema.EventPayloadKeys.body: "We DECIDE: \(sentinel)",
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
            try Bool.fetchOne(
                rawDB,
                sql:
                    "SELECT count(*)>0 FROM decisions WHERE reasoning_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inDecisions, "Sanity: sentinel should be in decisions before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                "linked_linear_id": "LEAF-42",
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
            try Bool.fetchOne(
                rawDB,
                sql:
                    "SELECT count(*)>0 FROM open_questions WHERE question_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inQuestions, "Sanity: sentinel should be in open_questions before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                "linked_linear_id": "LEAF-7",
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
            try Bool.fetchOne(
                rawDB,
                sql:
                    "SELECT count(*)>0 FROM blockers WHERE blocker_excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inBlockers, "Sanity: sentinel should be in blockers before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
            try Bool.fetchOne(
                rawDB,
                sql:
                    "SELECT count(*)>0 FROM where_stopped_log WHERE excerpt LIKE '%' || ? || '%'",
                arguments: [sentinel]) ?? false
        }
        XCTAssertTrue(inLog, "Sanity: sentinel should be in where_stopped_log before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                "linked_linear_id": "LEAF-100",
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
            let inDecisions =
                try Bool.fetchOne(
                    rawDB,
                    sql:
                        "SELECT count(*)>0 FROM decisions WHERE reasoning_excerpt LIKE '%' || ? || '%'",
                    arguments: [decisionSentinel]) ?? false
            XCTAssertTrue(inDecisions, "Sanity: decisions populated")

            let inOpenQ =
                try Bool.fetchOne(
                    rawDB,
                    sql:
                        "SELECT count(*)>0 FROM open_questions WHERE question_excerpt LIKE '%' || ? || '%'",
                    arguments: [openQSentinel]) ?? false
            XCTAssertTrue(inOpenQ, "Sanity: open_questions populated")

            let inBlockers =
                try Bool.fetchOne(
                    rawDB,
                    sql:
                        "SELECT count(*)>0 FROM blockers WHERE blocker_excerpt LIKE '%' || ? || '%'",
                    arguments: [blockerSentinel]) ?? false
            XCTAssertTrue(inBlockers, "Sanity: blockers populated")

            let inWhereStopped =
                try Bool.fetchOne(
                    rawDB,
                    sql:
                        "SELECT count(*)>0 FROM where_stopped_log WHERE excerpt LIKE '%' || ? || '%'",
                    arguments: [whereStoppedSentinel]) ?? false
            XCTAssertTrue(inWhereStopped, "Sanity: where_stopped_log populated")
        }

        // Negative invariant: NONE of the sentinels appear in presence_state.
        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty)
            XCTAssertFalse(
                stateJSON.contains(decisionSentinel),
                "Decision sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains(openQSentinel),
                "OpenQuestion sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains(blockerSentinel),
                "Blocker sentinel must not appear in presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains(whereStoppedSentinel),
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
                "body": "Alice mentioned you in LEAF-42 rebuild_oauth",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("rebuild_oauth"),
                "D1 notification title MUST NOT leak into presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains("Alice mentioned"),
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
                "reacted_at_ms": "100",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("rocket-unique-marker"),
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
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_GIST",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_GIST"),
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
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_RELEASE changelog with details",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_RELEASE"),
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
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_DEPLOY description text",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_DEPLOY"),
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
                Schema.EventPayloadKeys.projectV2NewValue: "BODY_SENTINEL_PROJECTV2_VALUE",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_PROJECTV2_VALUE"),
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
                "repo": "o/r",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_CODESPACE_NAME"),
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
                Schema.EventPayloadKeys.repoInvitationFromLogin: "BODY_SENTINEL_INVITER_LOGIN",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_INVITER_LOGIN"),
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
                Schema.EventPayloadKeys.alertRule: "BODY_SENTINEL_ALERT_RULE",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_ALERT_RULE"),
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
                Schema.EventPayloadKeys.auditAction: "BODY_SENTINEL_AUDIT_ACTION",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_AUDIT_ACTION"),
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
                Schema.EventPayloadKeys.body: "BODY_SENTINEL_REACTION_EMOJI",
            ]
        )
        try db.write(event)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='github'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("BODY_SENTINEL_REACTION_EMOJI"),
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
                "started_at_ms": "100",
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
                "completed_at_ms": "100",
            ]
        )
        try db.write(rel)
        try db.write(triage)

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")?[
                    "state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains("LEAF-99-unique-marker"),
                "D1 relation target_identifier MUST NOT leak")
            XCTAssertFalse(
                stateJSON.contains("Done-canary-marker"),
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
                Schema.EventPayloadKeys.body: sentinel,
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
            try Int.fetchOne(
                rawDB,
                sql:
                    "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                arguments: [Schema.BodyKinds.slackCanvasTitle]) ?? 0
        }
        XCTAssertEqual(
            ftsCount, 1,
            "Sanity: canvas title should be indexed under slack_canvas_title before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.body: sentinel,
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
            try Int.fetchOne(
                rawDB,
                sql:
                    "SELECT COUNT(*) FROM events_fts_meta WHERE body_kind = ?",
                arguments: [Schema.BodyKinds.slackBookmarkTitle]) ?? 0
        }
        XCTAssertEqual(
            ftsCount, 1,
            "Sanity: bookmark title should be indexed under slack_bookmark_title before asserting it does not leak")

        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after seed")
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.pinnedAtMs: "100",
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
            let ftsHits =
                try Int.fetchOne(
                    rawDB,
                    sql:
                        "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(
                ftsHits, 0,
                "Pin events MUST NOT produce FTS rows (no body-kind dispatch entry)")
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.dueTs: "200",
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
            let ftsHits =
                try Int.fetchOne(
                    rawDB,
                    sql:
                        "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(
                ftsHits, 0,
                "Reminder events MUST NOT produce FTS rows (reminder.text is dropped at provider boundary)")
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.channelId: "C1",
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
            let ftsHits =
                try Int.fetchOne(
                    rawDB,
                    sql:
                        "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(
                ftsHits, 0,
                "Scheduled-message events MUST NOT produce FTS rows (scheduled body is dropped at provider boundary)")
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.workspaceId: "W1",
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
            let ftsHits =
                try Int.fetchOne(
                    rawDB,
                    sql:
                        "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(
                ftsHits, 0,
                "Custom emoji events MUST NOT produce FTS rows (image URL is dropped at provider boundary)")
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                Schema.EventPayloadKeys.workspaceId: "W1",
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
            let ftsHits =
                try Int.fetchOne(
                    rawDB,
                    sql:
                        "SELECT COUNT(*) FROM events_fts_meta") ?? 0
            XCTAssertEqual(
                ftsHits, 0,
                "Usergroup membership events MUST NOT produce FTS rows (no body-kind dispatch entry)")
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='slack'")?["state_json"] as String?) ?? ""
            XCTAssertFalse(
                stateJSON.contains(sentinel),
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
                "title": titleMarker,
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
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?)
                ?? ""
            XCTAssertFalse(
                stateJSON.contains(titleMarker),
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
                "mode_name": modeNameMarker,
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
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?)
                ?? ""
            XCTAssertFalse(
                stateJSON.contains(modeNameMarker),
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
                "host": hostMarker,
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
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?)
                ?? ""
            XCTAssertFalse(
                stateJSON.contains(hostMarker),
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
                "space_id": spaceIDMarker,
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
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?)
                ?? ""
            XCTAssertFalse(
                stateJSON.contains(spaceIDMarker),
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
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='linear'")?["state_json"] as String?)
                ?? ""
            for m in markers {
                XCTAssertFalse(
                    stateJSON.contains(m),
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
                "content": "SECRET-JETBRAINS-CONTENT-S2",
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
                "plaintext": "SECRET-NOTE-PLAINTEXT-MARKER-S2",
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
                "notes": "SECRET-REMINDER-NOTES-S2",
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
                "attendees": "SECRET-ATTENDEES-LIST-S2",
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
                "from": "SECRET-MAIL-FROM-S2",
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
                "password": "SECRET-ZOOM-PASSWORD-S2",
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
                "chat_history": "SECRET-ZOOM-CHAT-S2",
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
                "history": "SECRET-SAFARI-HISTORY-S2",
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
                "source": "SECRET-CHROME-SOURCE-S2",
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
                "source": "SECRET-ARC-SOURCE-S2",
            ],
            markers: ["SECRET-ARC-COOKIES-S2", "SECRET-ARC-SOURCE-S2"],
            collectorID: "applescript_arc"
        )
    }

    // MARK: - Phase Track-6 P3 — browsers deep walkbacks (8 sentinel + 2 bypass)
    //
    // These tests verify that adversarial payload fields injected into a P3
    // event_kind do NOT leak into `presence_state.state_json` via the
    // `writeEventsOffsetAndPresence` write path. This is a structural sanity
    // check, not an end-to-end privacy assertion — the genuine guard against
    // URL/title bypass lives in the adapter filter (URLs are domain-collapsed
    // before they ever reach a state machine). See spec §14.1.

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
                "autofill": "SECRET-SAFARI-NAV-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-SAFARI-NAV-COOKIES-P3",
                "SECRET-SAFARI-NAV-SOURCE-P3",
                "SECRET-SAFARI-NAV-HISTORY-P3",
                "SECRET-SAFARI-NAV-FORM-P3",
                "SECRET-SAFARI-NAV-AUTOFILL-P3",
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
                "autofill": "SECRET-CHROME-NAV-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-CHROME-NAV-COOKIES-P3",
                "SECRET-CHROME-NAV-SOURCE-P3",
                "SECRET-CHROME-NAV-HISTORY-P3",
                "SECRET-CHROME-NAV-FORM-P3",
                "SECRET-CHROME-NAV-AUTOFILL-P3",
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
                "autofill": "SECRET-ARC-NAV-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-ARC-NAV-COOKIES-P3",
                "SECRET-ARC-NAV-SOURCE-P3",
                "SECRET-ARC-NAV-HISTORY-P3",
                "SECRET-ARC-NAV-FORM-P3",
                "SECRET-ARC-NAV-AUTOFILL-P3",
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
                "autofill": "SECRET-SAFARI-ACT-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-SAFARI-ACT-COOKIES-P3",
                "SECRET-SAFARI-ACT-SOURCE-P3",
                "SECRET-SAFARI-ACT-HISTORY-P3",
                "SECRET-SAFARI-ACT-FORM-P3",
                "SECRET-SAFARI-ACT-AUTOFILL-P3",
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
                "autofill": "SECRET-CHROME-ACT-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-CHROME-ACT-COOKIES-P3",
                "SECRET-CHROME-ACT-SOURCE-P3",
                "SECRET-CHROME-ACT-HISTORY-P3",
                "SECRET-CHROME-ACT-FORM-P3",
                "SECRET-CHROME-ACT-AUTOFILL-P3",
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
                "autofill": "SECRET-ARC-ACT-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-ARC-ACT-COOKIES-P3",
                "SECRET-ARC-ACT-SOURCE-P3",
                "SECRET-ARC-ACT-HISTORY-P3",
                "SECRET-ARC-ACT-FORM-P3",
                "SECRET-ARC-ACT-AUTOFILL-P3",
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
                "autofill": "SECRET-CHROME-BM-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-CHROME-BM-COOKIES-P3",
                "SECRET-CHROME-BM-SOURCE-P3",
                "SECRET-CHROME-BM-HISTORY-P3",
                "SECRET-CHROME-BM-FORM-P3",
                "SECRET-CHROME-BM-AUTOFILL-P3",
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
                "autofill": "SECRET-SAFARI-BM-AUTOFILL-P3",
            ],
            markers: [
                "SECRET-SAFARI-BM-COOKIES-P3",
                "SECRET-SAFARI-BM-SOURCE-P3",
                "SECRET-SAFARI-BM-HISTORY-P3",
                "SECRET-SAFARI-BM-FORM-P3",
                "SECRET-SAFARI-BM-AUTOFILL-P3",
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
                "title": "SECRET-DOMAIN-IN-TITLE-P3",
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
                "title": "Secret · LEAF-SECRET-P3",
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
                "body": "SECRET-INTENSITY-BODY-S3",
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
                "body": "SECRET-DROPPED-BUCKET-BODY-S3",
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
                "manufacturer": "SECRET-MANUFACTURER-S3",
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
                "audio_samples": "SECRET-MIC-SAMPLES-S3",
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
                "audio_samples": "SECRET-MIC-EXIT-S3",
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
                "screen_image": "SECRET-DISPLAY-PIXELS-S3",
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
                "screen_image": "SECRET-DISCONNECT-PIXELS-S3",
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
                "username": "SECRET-VPN-USER-S3",
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
                "bssid": "SECRET-WIFI-BSSID-S3",
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
                "body": "SECRET-CLIPBOARD-BODY-S3",
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
                "image_data": "SECRET-SCREENSHOT-PIXELS-S3",
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
                "source_url": "SECRET-DOWNLOAD-URL-S3",
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
                "body": "SECRET-TRASH-BODY-S3",
            ],
            markers: ["SECRET-TRASH-FILENAME-S3", "SECRET-TRASH-BODY-S3"],
            collectorID: "local_files"
        )
    }

    // MARK: - Track-6 P1 — Claude Code

    /// Track-6 P1 Phase D — claude_* event payloads (constructed with realistic
    /// allowlisted fields per Tasks 8-11) must not bleed into presence_state
    /// when written in the SAME atomic TX. The parser allowlist is the actual
    /// privacy fence — exercised directly by the moat-side sentinel walkback
    /// in `LeafCorePrivateTests/ClaudeCodeCollectorCrossHookTests`. This
    /// public-side counterpart verifies the OTHER half of the contract: even
    /// with AI-collab events written, `presence_state.state_json` cannot pull
    /// from event payload keys.
    ///
    /// Provider note: `PresenceStateWriter.Provider` has no `.anthropicClaude`
    /// case in Phase 4.7 — `.derived` is the reserved AI/Phase-4.9 row. Using
    /// `.derived` here doubles as a cross-isolation check (events sharing the
    /// TX with the "derived" presence row don't leak into it).
    func testEventBodyDoesNotLeakIntoPresenceState_ClaudeCode() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Realistic AI events with allowlisted-only payload (mirrors what the
        // moat parser actually emits per Tasks 8-11). NO forbidden fields here —
        // the parser-side allowlist is enforced by the sentinel walkback test
        // under LeafCorePrivateTests (moat). This public-side test checks the
        // OTHER half: writer + presence_state composition isolation.
        let toolUseEvent = RawEvent(
            timestamp: Date(),
            signalType: .aiCollaboration,
            bundleID: "com.anthropic.claude-code",
            payload: [
                "event_kind": "claude_bash_executed",
                "session_id": "S-LEAK",
                "command_length_chars": "23",
                "tool_use_id": "toolu_x",
                "source": "jsonl",
                "cwd": "/Users/x/proj",
            ]
        )
        let promptEvent = RawEvent(
            timestamp: Date(),
            signalType: .aiCollaboration,
            bundleID: "com.anthropic.claude-code",
            payload: [
                "event_kind": "claude_prompt_submitted",
                "session_id": "S-LEAK",
                "prompt_length_chars": "180",
                "source": "jsonl",
            ]
        )
        let tokensEvent = RawEvent(
            timestamp: Date(),
            signalType: .aiCollaboration,
            bundleID: "com.anthropic.claude-code",
            payload: [
                "event_kind": "claude_tokens_used",
                "session_id": "S-LEAK",
                "model": "claude-opus-4-7",
                "input_tokens": "5",
                "output_tokens": "732",
                "cache_creation_input_tokens": "100645",
                "cache_read_input_tokens": "0",
                "service_tier": "standard",
                "source": "jsonl",
            ]
        )

        // Realistic AI presence state (composed independently from events).
        // Uses `.derived` provider — the reserved Phase-4.9 mode-classifier row.
        let presenceState: [String: Any] = [
            "active_session_id": "S-LEAK",
            "current_model": "claude-opus-4-7",
            "tokens_in_last_minute": 737,
        ]
        try db.writeEventsOffsetAndPresence(
            [toolUseEvent, promptEvent, tokensEvent],
            offset: makeOffset(collectorID: CollectorID.claudeCodeJSONL, sourceID: "claude:test", nowMs: nowMs),
            presence: (provider: .derived, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='derived'")
            let stateJSON = (row?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after upsert")

            // Event-payload keys MUST NOT appear in presence_state.state_json —
            // even though events + presence were written in the same TX, the
            // writer composes presence from `state` only.
            XCTAssertFalse(stateJSON.contains("event_kind"))
            XCTAssertFalse(stateJSON.contains("tool_use_id"))
            XCTAssertFalse(stateJSON.contains("command_length_chars"))
            XCTAssertFalse(stateJSON.contains("prompt_length_chars"))
            XCTAssertFalse(stateJSON.contains("cache_creation"))
            XCTAssertFalse(stateJSON.contains("cache_read"))
            XCTAssertFalse(stateJSON.contains("input_tokens"))
            XCTAssertFalse(stateJSON.contains("output_tokens"))

            // It SHOULD contain the realistic presence keys we composed.
            XCTAssertTrue(stateJSON.contains("active_session_id"))
            XCTAssertTrue(stateJSON.contains("current_model"))
            XCTAssertTrue(stateJSON.contains("tokens_in_last_minute"))
        }
    }

    // MARK: - Phase Track-6 P4 — Google Calendar mapper walkbacks (42 = 7×6)
    //
    // Mapper-level sweep — for each of 6 google_calendar_* event_kinds and
    // each of 7 forbidden-field families, inject a unique sentinel through
    // the Codable boundary (raw JSON → JSONDecoder → GoogleCalendarAPI.Event)
    // and assert the sentinel does NOT appear in the mapper's output payload
    // when serialised to JSON. Spec §6.4 forbidden-fields, §11.2 walkback
    // strategy.
    //
    // Defense-in-depth: some sentinels (conferenceData.entryPoints[].uri,
    // workingLocationProperties.officeLocation.buildingId / customLocation.label)
    // are filtered at the Codable boundary by `GoogleCalendarAPI` —
    // intentionally not decoded. The test still passes (sentinel absent
    // from output) and locks-in that property too.
    //
    // Presence-state walkback is NOT duplicated here: the
    // `GoogleCalendarCollector` composite write feeds
    // `presence_state.google_calendar.state_json` only with counts / bools /
    // bucket enums (last_synced_at_ms, in_focus_block, working_location_type,
    // etc.) — no user-authored fields ever flow that path. The
    // mapper-output sweep below is the relevant ADR-010 enforcement.

    /// One sentinel per forbidden-field family (spec §6.4).
    private static let googleCalendarSentinels: [(field: String, sentinel: String)] = [
        ("description", "SECRET-GCAL-DESC-WALKBACK"),
        ("location", "SECRET-GCAL-LOC-WALKBACK"),
        ("attendees[].email", "SECRET-GCAL-ATTENDEE-WALKBACK@evil.example.com"),
        (
            "focusTimeProperties|outOfOfficeProperties.declineMessage",
            "SECRET-GCAL-DECLINE-WALKBACK"
        ),
        ("conferenceData.entryPoints[].uri", "SECRET-GCAL-CONF-URI-WALKBACK"),
        (
            "workingLocationProperties.officeLocation.buildingId",
            "SECRET-GCAL-BUILDING-WALKBACK"
        ),
        ("workingLocationProperties.customLocation.label", "SECRET-GCAL-CUSTOM-LOC-WALKBACK"),
    ]

    /// Mapping from event_kind to the Google API `eventType` string we need
    /// in synthetic JSON so the mapper's `(eventType, phase)` switch resolves.
    /// `_event_observed` is omnibus and accepts any eventType — we use
    /// "default" so external_attendee_count etc. all compute normally.
    private static func googleCalendarEventTypeForKind(_ kind: GoogleCalendarEventKind) -> String {
        switch kind {
        case .eventObserved: return "default"
        case .focusBlockStarted: return "focusTime"
        case .focusBlockEnded: return "focusTime"
        case .oooStarted: return "outOfOffice"
        case .oooEnded: return "outOfOffice"
        case .workingLocationChanged: return "workingLocation"
        }
    }

    /// Build an adversarial Google Calendar JSON event with the sentinel
    /// planted at every forbidden path we care about — then we override one
    /// specific path for the test focus. Building once with all sentinels
    /// would conflate failures across fields; instead we build per-pair.
    ///
    /// Strategy: ALL non-targeted forbidden paths get neutral non-sentinel
    /// values (`""` or omission). ONLY the targeted field carries the
    /// sentinel for this assertion. That way a regression at any single
    /// field surfaces a clear failure attribution `(kind, field)`.
    private static func makeGoogleCalendarJSON(
        kind: GoogleCalendarEventKind,
        field: String,
        sentinel: String
    ) -> String {
        let eventType = googleCalendarEventTypeForKind(kind)

        // Per-field injection — leave non-targeted forbidden paths empty.
        let description = field == "description" ? sentinel : ""
        let location = field == "location" ? sentinel : ""
        let attendeeEmail = field == "attendees[].email" ? sentinel : "noreply@example.com"
        let declineMessage = field == "focusTimeProperties|outOfOfficeProperties.declineMessage" ? sentinel : ""
        let confURI = field == "conferenceData.entryPoints[].uri" ? sentinel : "https://meet.example.com/abc"
        let buildingId = field == "workingLocationProperties.officeLocation.buildingId" ? sentinel : ""
        let customLabel = field == "workingLocationProperties.customLocation.label" ? sentinel : ""

        // JSON-escape every interpolated string (sentinels contain no `"` or
        // backslash, but `attendeeEmail` is an arbitrary email — be safe).
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        return """
            {
              "id": "gcal-evt-walkback",
              "iCalUID": "gcal-evt-walkback@google.com",
              "status": "confirmed",
              "summary": "Walkback synthetic",
              "description": "\(esc(description))",
              "location": "\(esc(location))",
              "start": {"dateTime": "2026-05-16T14:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "\(eventType)",
              "htmlLink": "https://calendar.google.com/event?eid=gcal-evt-walkback",
              "organizer": {"email": "organizer@example.com", "self": true},
              "creator":   {"email": "creator@example.com",   "self": true},
              "attendees": [
                {"email": "\(esc(attendeeEmail))", "responseStatus": "accepted", "self": true}
              ],
              "conferenceData": {
                "entryPoints": [
                  {"entryPointType": "video", "uri": "\(esc(confURI))", "pin": "1234", "accessCode": "ZZ", "password": "p", "passcode": "pc", "meetingCode": "mc"}
                ],
                "conferenceSolution": {"key": {"type": "hangoutsMeet"}}
              },
              "focusTimeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "\(esc(declineMessage))",
                "chatStatus": "doNotDisturb"
              },
              "outOfOfficeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "\(esc(declineMessage))"
              },
              "workingLocationProperties": {
                "type": "officeLocation",
                "officeLocation": {
                  "buildingId": "\(esc(buildingId))",
                  "floorId": "F2",
                  "deskId": "D17",
                  "label": "Headquarters"
                },
                "customLocation": {"label": "\(esc(customLabel))"}
              }
            }
            """
    }

    /// Invoke the right mapper entry point for `kind` and return the
    /// resulting payload dict (or `[:]` if mapper returned nil — a regression
    /// would have to first restore payload emission to leak anything).
    private func mapGoogleCalendarEvent(
        _ event: GoogleCalendarAPI.Event,
        kind: GoogleCalendarEventKind
    ) -> [String: Any] {
        let calendar = GoogleCalendarSyncTokenStore.KnownCalendar(
            id: "me@example.com",
            summary: "primary",
            summaryOverride: nil,
            accessRole: "owner",
            primary: true,
            colorId: nil,
            timeZone: "Europe/Berlin"
        )
        switch kind {
        case .eventObserved:
            return GoogleCalendarEventMapper.makeObservedPayload(
                event, calendar: calendar, userDomain: "example.com"
            ) ?? [:]
        case .focusBlockStarted:
            return GoogleCalendarEventMapper.makeTransitionPayload(
                event: event, phase: .started, calendarId: calendar.id
            ) ?? [:]
        case .focusBlockEnded:
            return GoogleCalendarEventMapper.makeTransitionPayload(
                event: event, phase: .ended, calendarId: calendar.id
            ) ?? [:]
        case .oooStarted:
            return GoogleCalendarEventMapper.makeTransitionPayload(
                event: event, phase: .started, calendarId: calendar.id
            ) ?? [:]
        case .oooEnded:
            return GoogleCalendarEventMapper.makeTransitionPayload(
                event: event, phase: .ended, calendarId: calendar.id
            ) ?? [:]
        case .workingLocationChanged:
            return GoogleCalendarEventMapper.makeTransitionPayload(
                event: event, phase: .changed, calendarId: calendar.id
            ) ?? [:]
        }
    }

    /// 42-assertion sweep: 6 event_kinds × 7 forbidden fields.
    /// Each (kind, field) pair injects a unique sentinel through the Codable
    /// boundary, runs the mapper, serialises the output payload to JSON, and
    /// asserts the sentinel substring is absent.
    func testEveryForbiddenSentinelIsStrippedFromGoogleCalendarPayloads() throws {
        for kind in GoogleCalendarEventKind.allCases {
            for (field, sentinel) in Self.googleCalendarSentinels {
                let json = Self.makeGoogleCalendarJSON(
                    kind: kind, field: field, sentinel: sentinel
                )
                let data = try XCTUnwrap(json.data(using: .utf8))
                let event = try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
                let payload = mapGoogleCalendarEvent(event, kind: kind)
                let serialised = try JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys]
                )
                let payloadJSON = String(data: serialised, encoding: .utf8) ?? ""
                XCTAssertFalse(
                    payloadJSON.contains(sentinel),
                    "Sentinel '\(sentinel)' for forbidden field '\(field)' leaked into "
                        + "\(kind.rawValue) mapper output: \(payloadJSON)"
                )
            }
        }
    }

    // MARK: - Phase Track-6 P5 — Zoom Deep walkbacks

    /// Helper specialized for P5: presence_state row is `.zoom` (mirrors the
    /// actual collector write path) and we assert sentinels never reach the
    /// composite presence row's state_json. 8 sentinel families × 3 P5 kinds
    /// = 24 walkbacks. PMI raw name handled by a separate end-to-end test.
    ///
    /// **Scope clarification (Track-6 P5 review):** this asserts only that
    /// `presence_state.zoom.state_json` is constructed via `buildZoomState(...)`
    /// from typed parameters — therefore it physically cannot include the
    /// adversarial `extraPayload` fields, regardless of what the input contains.
    /// The strong guarantee here is the **builder's allowlisted-key schema**
    /// (locked by `PresenceStateWriterZoomTests.testStateBuilderRefusesRawURLOrTitleByOmission`).
    /// These walkbacks add coverage at the write-time boundary: if a future
    /// refactor changes `upsert` to read from event payload instead of the
    /// builder-constructed dict, the sentinels would leak and this test would
    /// catch it. Phase 5.4 follow-up will add relay-broadcast-pipeline walkbacks
    /// once `presence_outgoing` (M011) lands.
    private func assertP5DoesNotLeakIntoZoomPresence(
        eventKind: String,
        extraPayload: [String: String],
        markers: [String],
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var payload: [String: String] = ["event_kind": eventKind, "source": "zoom"]
        for (k, v) in extraPayload { payload[k] = v }
        let event = RawEvent(
            timestamp: Date(),
            signalType: .context,
            bundleID: "us.zoom.xos",
            payload: payload
        )
        // Realistic P5 presence_state.zoom write — composite row, no PII fields.
        let zoomPresence = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: nowMs - 60_000,
            coldStart: false,
            linkedCalendarEventID: "safehash00000000",
            lastObservedAtMs: nowMs
        )
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: "applescript_zoom", sourceID: "applescript_zoom:test", nowMs: nowMs),
            presence: (provider: .zoom, state: zoomPresence, derivedMode: nil),
            nowMs: nowMs
        )
        try db.readSQL { rawDB in
            let stateJSON =
                (try Row.fetchOne(
                    rawDB,
                    sql:
                        "SELECT state_json FROM presence_state WHERE provider='zoom'")?["state_json"] as String?) ?? ""
            for m in markers {
                XCTAssertFalse(
                    stateJSON.contains(m),
                    "Marker '\(m)' MUST NOT appear in presence_state.zoom.state_json for \(eventKind)",
                    file: file, line: line)
            }
        }
    }

    // 8 sentinel families × 3 P5 kinds = 24 walkbacks.
    // Families: attendees, password, chat_history, recording_state,
    //           participant_names, screen_share_content, meeting_join_url, conference_uri.

    // -- zoom_meeting_started (8) --

    func testRelayDoesNotLeakZoomAttendees_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["attendees": "SECRET-ZOOM-ATTENDEES-P5"],
            markers: ["SECRET-ZOOM-ATTENDEES-P5"]
        )
    }
    func testRelayDoesNotLeakZoomPassword_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["password": "SECRET-ZOOM-PASSWORD-P5"],
            markers: ["SECRET-ZOOM-PASSWORD-P5"]
        )
    }
    func testRelayDoesNotLeakZoomChatHistory_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["chat_history": "SECRET-ZOOM-CHAT-P5"],
            markers: ["SECRET-ZOOM-CHAT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomRecordingState_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["recording_state": "SECRET-ZOOM-RECORDING-P5"],
            markers: ["SECRET-ZOOM-RECORDING-P5"]
        )
    }
    func testRelayDoesNotLeakZoomParticipantNames_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["participant_names": "SECRET-ZOOM-PARTICIPANTS-P5"],
            markers: ["SECRET-ZOOM-PARTICIPANTS-P5"]
        )
    }
    func testRelayDoesNotLeakZoomShareContent_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["screen_share_content": "SECRET-ZOOM-SHARE-CONTENT-P5"],
            markers: ["SECRET-ZOOM-SHARE-CONTENT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomJoinURL_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["meeting_join_url": "SECRET-ZOOM-JOIN-URL-P5"],
            markers: ["SECRET-ZOOM-JOIN-URL-P5"]
        )
    }
    func testRelayDoesNotLeakZoomConferenceURI_P5_Started() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["conference_uri": "SECRET-ZOOM-CONFERENCE-URI-P5"],
            markers: ["SECRET-ZOOM-CONFERENCE-URI-P5"]
        )
    }

    // -- zoom_meeting_ended (8) --

    func testRelayDoesNotLeakZoomAttendees_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["attendees": "SECRET-ZOOM-ATTENDEES-P5"],
            markers: ["SECRET-ZOOM-ATTENDEES-P5"]
        )
    }
    func testRelayDoesNotLeakZoomPassword_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["password": "SECRET-ZOOM-PASSWORD-P5"],
            markers: ["SECRET-ZOOM-PASSWORD-P5"]
        )
    }
    func testRelayDoesNotLeakZoomChatHistory_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["chat_history": "SECRET-ZOOM-CHAT-P5"],
            markers: ["SECRET-ZOOM-CHAT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomRecordingState_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["recording_state": "SECRET-ZOOM-RECORDING-P5"],
            markers: ["SECRET-ZOOM-RECORDING-P5"]
        )
    }
    func testRelayDoesNotLeakZoomParticipantNames_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["participant_names": "SECRET-ZOOM-PARTICIPANTS-P5"],
            markers: ["SECRET-ZOOM-PARTICIPANTS-P5"]
        )
    }
    func testRelayDoesNotLeakZoomShareContent_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["screen_share_content": "SECRET-ZOOM-SHARE-CONTENT-P5"],
            markers: ["SECRET-ZOOM-SHARE-CONTENT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomJoinURL_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["meeting_join_url": "SECRET-ZOOM-JOIN-URL-P5"],
            markers: ["SECRET-ZOOM-JOIN-URL-P5"]
        )
    }
    func testRelayDoesNotLeakZoomConferenceURI_P5_Ended() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_ended",
            extraPayload: ["conference_uri": "SECRET-ZOOM-CONFERENCE-URI-P5"],
            markers: ["SECRET-ZOOM-CONFERENCE-URI-P5"]
        )
    }

    // -- zoom_meeting_calendar_linked (8) --

    func testRelayDoesNotLeakZoomAttendees_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["attendees": "SECRET-ZOOM-ATTENDEES-P5"],
            markers: ["SECRET-ZOOM-ATTENDEES-P5"]
        )
    }
    func testRelayDoesNotLeakZoomPassword_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["password": "SECRET-ZOOM-PASSWORD-P5"],
            markers: ["SECRET-ZOOM-PASSWORD-P5"]
        )
    }
    func testRelayDoesNotLeakZoomChatHistory_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["chat_history": "SECRET-ZOOM-CHAT-P5"],
            markers: ["SECRET-ZOOM-CHAT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomRecordingState_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["recording_state": "SECRET-ZOOM-RECORDING-P5"],
            markers: ["SECRET-ZOOM-RECORDING-P5"]
        )
    }
    func testRelayDoesNotLeakZoomParticipantNames_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["participant_names": "SECRET-ZOOM-PARTICIPANTS-P5"],
            markers: ["SECRET-ZOOM-PARTICIPANTS-P5"]
        )
    }
    func testRelayDoesNotLeakZoomShareContent_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["screen_share_content": "SECRET-ZOOM-SHARE-CONTENT-P5"],
            markers: ["SECRET-ZOOM-SHARE-CONTENT-P5"]
        )
    }
    func testRelayDoesNotLeakZoomJoinURL_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["meeting_join_url": "SECRET-ZOOM-JOIN-URL-P5"],
            markers: ["SECRET-ZOOM-JOIN-URL-P5"]
        )
    }
    func testRelayDoesNotLeakZoomConferenceURI_P5_CalendarLinked() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_calendar_linked",
            extraPayload: ["conference_uri": "SECRET-ZOOM-CONFERENCE-URI-P5"],
            markers: ["SECRET-ZOOM-CONFERENCE-URI-P5"]
        )
    }

    /// PMI sentinel — verifies that the raw "<First> <Last>'s Personal Meeting Room"
    /// string never lands in presence_state.zoom (the redactor at parser boundary
    /// converts to "<pmi_meeting>" bucket before the observation reaches state machines).
    /// This test runs at the relay-write layer; redaction unit tests in
    /// ProdZoomMeetingTopicRedactorTests cover the regex itself.
    func testRelayDoesNotLeakRawPMIName_P5() throws {
        try assertP5DoesNotLeakIntoZoomPresence(
            eventKind: "zoom_meeting_started",
            extraPayload: ["meeting_topic": "Dmitrii Demidov's Personal Meeting Room"],
            markers: ["Dmitrii Demidov's Personal Meeting Room"]
        )
    }
    // MARK: - Track-6 P6 — vscode/JetBrains sentinel walkbacks

    func test_p6_walkback_vscodeActiveDocChanged_fileBodyNeverLeaks() {
        // Interpretation A: use a title that does NOT match the default "file — workspace — appName"
        // shape (no " — " or " - " separator) so the parser returns nil and the fallback
        // sanitizer path is exercised. A title with " — " separators would produce a non-nil
        // VSCodeObservation whose workspaceName contains the sentinel — which is the parser's
        // expected (correct) behavior when upstream passes an arbitrary path as ${rootName}.
        // This walkback tests the *sanitizer* branch, not the parser success path.
        let sentinel = "LEAKED_SENTINEL_VSCODE_P6_FILE_BODY"
        let titleWithSentinel = "Custom [active] Foo.swift @ /Users/alice/\(sentinel)/project @ VSCode"
        guard let obs = VSCodeStableParser.parse(titleWithSentinel) else {
            // Parser correctly returns nil for non-default shape — fallback path:
            let sanitized = IDETitlePathSanitizer.sanitize(titleWithSentinel)
            XCTAssertFalse(
                sanitized.contains("/Users/alice"),
                "absolute home path leaked through fallback sanitizer: \(sanitized)")
            XCTAssertFalse(
                sanitized.contains("/project"),
                "intermediate path component leaked through fallback sanitizer: \(sanitized)")
            return
        }
        // If the parser somehow matched (future format change), assert only basename fields.
        XCTAssertFalse(
            obs.workspaceName?.contains("/Users/alice") ?? false,
            "absolute path leaked into workspaceName: \(obs.workspaceName ?? "")")
        XCTAssertFalse(
            obs.fileBasename?.contains(sentinel) ?? false,
            "sentinel leaked into fileBasename: \(obs.fileBasename ?? "")")
    }

    func test_p6_walkback_vscodeWorkspaceOpened_pathNeverLeaks() {
        // Track-9 T1 refactor: post-T1, basename position MAY appear in payload
        // via the new `workspace_root` field (~/-prefixed). Sentinel now lives
        // at the USERNAME position (which MUST never leak per ADR-010). Assert
        // both: the username sentinel never appears, AND no `/Users/` absolute
        // prefix anywhere.
        let sentinel = "LEAKED_SENTINEL_VSCODE_USERNAME"
        let mockHomeDir = "/Users/\(sentinel)"
        let json = #"{"folder":"file://\#(mockHomeDir)/Desktop/myws"}"#
        guard let parsed = VSCodeWorkspaceWatcher.parseWorkspaceJSON(json, homeDir: mockHomeDir) else {
            XCTFail("parser failed; cannot test walkback")
            return
        }
        let event = VSCodeWorkspaceWatcher.buildEvent(
            bundleID: "com.microsoft.VSCode",
            workspaceName: parsed.workspaceName,
            sanitizedPath: parsed.sanitizedPath,
            watchedFolderID: nil,
            nowMs: 1_000,
            workspaceRootEnabled: true
        )
        for (key, value) in event.payload {
            XCTAssertFalse(
                value.contains(sentinel),
                "username sentinel leaked through walkback: \(key)=\(value)")
            XCTAssertFalse(
                value.contains("/Users/"),
                "absolute /Users/ prefix leaked through walkback: \(key)=\(value)")
        }
        // Positive check: sanitized form makes it into workspace_root.
        XCTAssertEqual(event.payload["workspace_root"], "~/Desktop/myws")
    }

    func test_p6_walkback_ideWindowTitleObserved_titleSanitized() {
        let sentinel = "LEAKED_SENTINEL_VSCODE_P6_TITLE"
        let customTitle = "[main] Foo.swift in /Users/alice/secret/\(sentinel) @ Visual Studio Code"
        let sanitized = IDETitlePathSanitizer.sanitize(customTitle)
        XCTAssertFalse(
            sanitized.contains("/Users/alice"),
            "absolute path in sanitized title: \(sanitized)")
        XCTAssertFalse(
            sanitized.contains("/secret"),
            "intermediate path component in sanitized title: \(sanitized)")
        // Basename of the sentinel path token IS retained — that's the
        // sanitizer's intended behavior. Verify it.
        XCTAssertTrue(sanitized.contains(sentinel))
    }

    func test_p6_walkback_jetbrainsRecentProjectObserved_runManagerNeverLeaks() {
        let sentinel = "LEAKED_SENTINEL_JB_P6"
        let xml = """
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo">
                  <map>
                    <entry key="$USER_HOME$/Desktop/leaf">
                      <value>
                        <RecentProjectMetaInfo activationTimestamp="1747000000000">
                          <option name="displayName" value="leaf" />
                          <runManager><secret>\(sentinel)</secret></runManager>
                          <frame><option name="extendedState" value="\(sentinel)-frame" /></frame>
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
                  </map>
                </option>
              </component>
            </application>
            """
        let entries = JetBrainsRecentProjectsWatcher.parseRecentProjectsXML(xml)
        XCTAssertEqual(entries.count, 1)
        for entry in entries {
            XCTAssertFalse(
                entry.displayName.contains(sentinel),
                "sentinel leaked into displayName: \(entry.displayName)")
        }
        // Walk the build event too.
        let event = JetBrainsRecentProjectsWatcher.buildEvent(
            bundleID: "com.jetbrains.intellij",
            versionDir: "IntelliJIdea2025.1",
            displayName: entries[0].displayName,
            activationTimestampMs: entries[0].activationTimestampMs,
            outsideWatchedFolder: true
        )
        for (key, value) in event.payload {
            XCTAssertFalse(
                value.contains(sentinel),
                "sentinel leaked through JetBrains walkback: \(key)=\(value)")
        }
    }

    /// Integration walkback: assert no P6 sentinel string of any flavor appears
    /// anywhere in the payload tree for all four event_kinds across realistic
    /// fixtures. Pattern locked since Track-4 S4 fix-bundle.
    func test_p6_walkback_integrationSentinelSweep() {
        let sentinels = [
            "LEAKED_SENTINEL_VSCODE_P6_FILE_BODY",
            "LEAKED_SENTINEL_VSCODE_USERNAME",
            "LEAKED_SENTINEL_VSCODE_P6_TITLE",
            "LEAKED_SENTINEL_JB_P6",
        ]
        var events: [RawEvent] = []

        // vscode_active_doc_changed — realistic title (no sentinel, confirm no
        // cross-contamination from prior tests).
        let title1 = "Foo.swift — leaf — Visual Studio Code"
        if let obs = VSCodeStableParser.parse(title1) {
            var sm = VSCodeStateMachine()
            events.append(contentsOf: sm.observe(obs, nowMs: 1_000))
        }

        // vscode_workspace_opened — absolute path sanitized to basename.
        if let parsed = VSCodeWorkspaceWatcher.parseWorkspaceJSON(
            #"{"folder":"file:///Users/alice/Desktop/leaf"}"#,
            homeDir: "/Users/alice"
        ) {
            events.append(
                VSCodeWorkspaceWatcher.buildEvent(
                    bundleID: "com.microsoft.VSCode",
                    workspaceName: parsed.workspaceName,
                    sanitizedPath: parsed.sanitizedPath,
                    watchedFolderID: nil,
                    nowMs: 1_000
                ))
        }

        // jetbrains_recent_project_observed — displayName only.
        events.append(
            JetBrainsRecentProjectsWatcher.buildEvent(
                bundleID: "com.jetbrains.pycharm",
                versionDir: "PyCharm2025.1",
                displayName: "ml-research",
                activationTimestampMs: 1_747_000_000_000,
                outsideWatchedFolder: true
            ))

        // ide_window_title_observed payload would only be built via the
        // planner; sanitizer is its sole privacy gate — covered by
        // test_p6_walkback_ideWindowTitleObserved_titleSanitized above.

        for event in events {
            let mirror = String(describing: event.payload)
            for sentinel in sentinels {
                XCTAssertFalse(
                    mirror.contains(sentinel),
                    "P6 sentinel \(sentinel) leaked in payload: \(mirror)")
            }
        }
    }

    // MARK: - Phase Track-8 P6 — INBOX

    /// Defense-in-depth regression guard. INBOX is local-render-only; this
    /// test asserts that body content from upstream Layer B / D3 events
    /// (which feed `open_questions` / `blockers` and ultimately the
    /// `DerivedInsights.inboxItems` surface) never round-trips into the
    /// `presence_state` broadcast envelope. Pattern mirrors the existing
    /// per-provider tests above. Padded body ensures the 60-char excerpt
    /// truncation would still expose the sentinel if mishandled.
    func testEventBodyDoesNotLeakIntoPresenceState_INBOX() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let sentinel = "LEAKED_SENTINEL_INBOX_BODY"
        let bodyText = "padding-prefix-padding-prefix-" + sentinel + "-padding-suffix-padding-suffix"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "com.linear.linear",
            payload: [
                "event_kind": "linear_comment_authored",
                "issue_key": "LEA-200",
                Schema.EventPayloadKeys.body: bodyText,
            ]
        )
        let presenceState: [String: Any] = ["inbox_count": 1]
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(collectorID: CollectorID.linearPolling, sourceID: "linear:inbox-test", nowMs: nowMs),
            presence: (provider: .linear, state: presenceState, derivedMode: nil),
            nowMs: nowMs
        )

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")
            let stateJSON = (row?["state_json"] as String?) ?? ""
            XCTAssertFalse(stateJSON.isEmpty, "presence_state row should exist after upsert")
            XCTAssertFalse(
                stateJSON.contains(sentinel),
                "INBOX sentinel '\(sentinel)' MUST NOT appear in presence_state.state_json")
            XCTAssertFalse(
                stateJSON.contains("\"body\""),
                "Payload key 'body' should not appear in presence_state.state_json")
        }
    }
}
