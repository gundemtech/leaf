// Phase Track-1 D1 — privacy regression: bodies must never reach presence_state JSON.
// Acceptance gate per Track 1 contract §6 (bodies on-device only — relay never sees).

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
                "event_kind": "pr_opened",
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
                "event_kind": "message_authored_aggregate",
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
                "event_kind": "linear_issue_updated",
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
                "event_kind": "linear_issue_updated",
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
}
