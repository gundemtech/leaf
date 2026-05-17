// Phase Track-1 D2 + Track-3 D2 — EventsFullTextStore body extraction (GitHub body kinds).
//
// Split from EventsFullTextStoreTests for type_body_length / file_length.

import GRDB
import XCTest

@testable import LeafCore

final class EventsFullTextStoreGitHubTests: XCTestCase {
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

    func testIndexEvent_GitHubPRBody() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "gh_pr_opened",
            Schema.EventPayloadKeys.body: "Summary fix the auth bug",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghPR)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "auth"))
    }

    func testIndexEvent_CommitMessage() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "gh_commit_pushed",
            Schema.EventPayloadKeys.body: "fix(auth): tighten token refresh",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "git", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.commitMsg)
    }

    func testIndexEvent_GitHubIssueCommentBody() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "gh_issue_comment_authored",
            Schema.EventPayloadKeys.body: "agreed, lets ship it",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghIssueComment)
    }

    func testIndexEvent_GitHubPRReviewCommentBody() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "gh_pr_review_comment_authored",
            Schema.EventPayloadKeys.body: "nit: extract this constant",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghPRReviewComment)
    }

    // MARK: - Track-3 D2 — gist / release / deployment body-kind dispatch

    func testIndexEvent_GitHubGistDescription_Created() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": GitHubEventKindKey.gistCreated.rawValue,
            Schema.EventPayloadKeys.body: "snippet for hkdf info string sample",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghGistDescription)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "hkdf"))
    }

    func testIndexEvent_GitHubGistDescription_Updated() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": GitHubEventKindKey.gistUpdated.rawValue,
            Schema.EventPayloadKeys.body: "edited description for snippet",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghGistDescription)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "edited"))
    }

    func testIndexEvent_GitHubReleaseBody() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": GitHubEventKindKey.releasePublished.rawValue,
            Schema.EventPayloadKeys.body: "v1.2.0 ships sparkle delta updates",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghReleaseBody)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "sparkle"))
    }

    func testIndexEvent_GitHubDeploymentDescription() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": GitHubEventKindKey.deploymentCreated.rawValue,
            Schema.EventPayloadKeys.body: "promote staging to production",
        ]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "github", payload: payload, in: rawDB
            )
        }
        let rows = try ftsMetaRowsForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bodyKind, Schema.BodyKinds.ghDeploymentDescription)
        XCTAssertTrue(try ftsContains(db, eventID: eid, query: "production"))
    }
}
