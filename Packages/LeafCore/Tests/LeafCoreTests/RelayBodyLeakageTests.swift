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
}
