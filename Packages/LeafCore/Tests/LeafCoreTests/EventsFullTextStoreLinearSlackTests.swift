// Phase Track-1 D2 — EventsFullTextStore body extraction (Linear + Slack body kinds).
//
// Split from EventsFullTextStoreTests for type_body_length / file_length.
// Verification mechanics (sidecar lookups + MATCH probes) mirror the helpers in
// EventsFullTextStoreTests.swift — duplicated inline by design.

import GRDB
import XCTest

@testable import LeafCore

final class EventsFullTextStoreLinearSlackTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-fts-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func insertRawEventRow(
        _ db: LeafCore.Database, signalType: String = "action", bundleID: String = "x"
    ) throws -> Int64 {
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, ?, ?, '{}')",
                arguments: [Int64(Date().timeIntervalSince1970 * 1000), signalType, bundleID]
            )
            return rawDB.lastInsertedRowID
        }
    }

    private func ftsMetaRowsForEvent(
        _ db: LeafCore.Database, eventID: Int64
    ) throws -> [(bodyKind: String, ftsRowID: Int64)] {
        try db.readSQL { rawDB in
            try Row.fetchAll(
                rawDB,
                sql: "SELECT body_kind, fts_rowid FROM events_fts_meta WHERE event_id = ? ORDER BY fts_rowid",
                arguments: [eventID]
            ).map { ($0["body_kind"] as String? ?? "", $0["fts_rowid"] as Int64? ?? 0) }
        }
    }

    private func ftsContains(_ db: LeafCore.Database, eventID: Int64, query: String) throws -> Bool {
        try db.readSQL { rawDB in
            try Bool.fetchOne(
                rawDB,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM events_fts
                        JOIN events_fts_meta ON events_fts_meta.fts_rowid = events_fts.rowid
                        WHERE events_fts MATCH ? AND events_fts_meta.event_id = ?
                    )
                    """, arguments: [query, eventID]) ?? false
        }
    }

    func testIndexEvent_LinearIssueDescription() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "issue_updated",
            Schema.EventPayloadKeys.body: "OAuth refactor",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "linear", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.linearDesc)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "OAuth"))
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "refactor"))
    }

    func testIndexEvent_LinearCommentBodies_FanOut() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let comments = #"[{"body":"first"},{"body":"second"},{"body":"third"}]"#
        let payload = [
            "event_kind": "issue_updated",
            Schema.EventPayloadKeys.body: "Description here",
            Schema.EventPayloadKeys.commentBodiesJson: comments,
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "linear", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.bodyKind == Schema.BodyKinds.linearDesc }.count, 1)
        XCTAssertEqual(rows.filter { $0.bodyKind == Schema.BodyKinds.linearComment }.count, 3)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "first"))
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "second"))
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "third"))
    }

    func testIndexEvent_SlackMessagesAggregate_FanOut() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let msgs = #"[{"text":"alpha"},{"text":"bravo"},{"text":"charlie"},{"text":"delta"},{"text":"echo"}]"#
        let payload = [
            "event_kind": "slack_message_aggregate",
            Schema.EventPayloadKeys.messagesJson: msgs,
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "slack", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.bodyKind == Schema.BodyKinds.slackMsg })
        for word in ["alpha", "bravo", "charlie", "delta", "echo"] {
            XCTAssertTrue(try ftsContains(db, eventID: eid, query: word))
        }
    }

    func testIndexEvent_SlackThreadReply_ParentPlusReplies() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let replies = #"[{"text":"reply alpha"},{"text":"reply bravo"}]"#
        let payload = [
            "event_kind": "slack_thread_reply_aggregate",
            Schema.EventPayloadKeys.body: "parent message",
            Schema.EventPayloadKeys.threadRepliesJson: replies,
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "slack", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter { $0.bodyKind == Schema.BodyKinds.slackThreadParent }.count, 1)
        XCTAssertEqual(rows.filter { $0.bodyKind == Schema.BodyKinds.slackThreadReply }.count, 2)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "parent"))
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "alpha"))
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "bravo"))
    }

    /// Track-1 D2 carry-over fix regression: LinearCollector emits event_kind
    /// "issue_updated" (no "linear_" prefix), but the FTS dispatcher checks
    /// "linear_issue_updated" — so Linear descriptions never reached the index.
    /// This test pins the corrected dispatch.
    func testLinearIssueUpdatedEventKindDispatchesToFTS() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "issue_updated",
                "issue_key": "LEAF-12",
                "title": "test",
                "status": "In Progress",
                "project": "",
                "team_key": "LEAF",
                Schema.EventPayloadKeys.body: "decided to migrate the auth refresh path",
            ]
        )
        try db.write(event)
        let hits = try db.readSQL { rawDB in
            try EventsFullTextStore.search(query: "auth refresh", period: 0...200_000, in: rawDB)
        }
        XCTAssertGreaterThan(hits.count, 0, "Linear issue_updated body must index into FTS5 after D1 carry-over fix")
    }

    func testLinearNotificationReceivedTitleIndexesViaFTS() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 50),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_notification_received",
                Schema.EventPayloadKeys.notificationId: "n1",
                Schema.EventPayloadKeys.notificationKind: "issueAssignedToYou",
                Schema.EventPayloadKeys.body: "Alice assigned LEAF-99 to you: rework migrations",
            ]
        )
        try db.write(event)
        let hits = try db.readSQL { rawDB in
            try EventsFullTextStore.search(query: "rework migrations", period: 0...100_000, in: rawDB)
        }
        XCTAssertGreaterThan(
            hits.count, 0, "linear_notification_received body must FTS-index under linear_notification_title body_kind")
    }
}
