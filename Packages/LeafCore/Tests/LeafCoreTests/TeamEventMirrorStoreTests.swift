// Phase Track-5 S5 — TeamEventMirrorStore CRUD invariants.

import XCTest
import GRDB
@testable import LeafCore

final class TeamEventMirrorStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-events-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRow(
        eventID: String = "evt-1",
        workspaceID: String = "wid",
        senderPubkeyHex: String = "shex",
        source: ShareSource = .gitCommits,
        kind: String = "gh_commit_pushed",
        plaintextPayloadJSON: String = "{\"fields\":{}}",
        serverCreatedAtMs: Int64 = 1_000,
        eventTsMs: Int64 = 990,
        receivedAtMs: Int64 = 1_010
    ) -> TeamEventMirrorRow {
        TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            source: source,
            kind: kind,
            plaintextPayloadJSON: plaintextPayloadJSON,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: eventTsMs,
            receivedAtMs: receivedAtMs
        )
    }

    func testUpsert_IsIdempotent() throws {
        let row = makeRow()
        try db.writeSQL { rawDB in try TeamEventMirrorStore.upsert(row, in: rawDB) }
        try db.writeSQL { rawDB in try TeamEventMirrorStore.upsert(row, in: rawDB) }
        try db.writeSQL { rawDB in try TeamEventMirrorStore.upsert(row, in: rawDB) }

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.TeamEventsMirror.tableName)")
        }
        XCTAssertEqual(count, 1)
    }

    func testReadRecent_OrdersByServerCreatedAtMsDesc() throws {
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e1", serverCreatedAtMs: 100), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e2", serverCreatedAtMs: 300), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e3", serverCreatedAtMs: 200), in: rawDB)
        }
        let rows = try db.readSQL { rawDB in
            try TeamEventMirrorStore.readRecent(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(rows.map { $0.eventID }, ["e2", "e3", "e1"])
    }

    func testReadBySender_FiltersByPubkey() throws {
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e1", senderPubkeyHex: "alice"), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e2", senderPubkeyHex: "bob"), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e3", senderPubkeyHex: "alice"), in: rawDB)
        }
        let alice = try db.readSQL { rawDB in
            try TeamEventMirrorStore.readBySender(workspaceID: "wid", senderPubkeyHex: "alice", in: rawDB)
        }
        XCTAssertEqual(Set(alice.map { $0.eventID }), ["e1", "e3"])
    }

    func testMaxServerCreatedAtMs_NilOnCold() throws {
        let watermark = try db.readSQL { rawDB in
            try TeamEventMirrorStore.maxServerCreatedAtMs(workspaceID: "wid", in: rawDB)
        }
        XCTAssertNil(watermark)
    }

    func testMaxServerCreatedAtMs_AfterInserts() throws {
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e1", serverCreatedAtMs: 100), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e2", serverCreatedAtMs: 500), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "e3", serverCreatedAtMs: 300), in: rawDB)
        }
        let watermark = try db.readSQL { rawDB in
            try TeamEventMirrorStore.maxServerCreatedAtMs(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(watermark, 500)
    }

    func testDeleteOlderThan_RemovesAndReturnsCount() throws {
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(makeRow(eventID: "old1", serverCreatedAtMs: 100), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "old2", serverCreatedAtMs: 200), in: rawDB)
            try TeamEventMirrorStore.upsert(makeRow(eventID: "new1", serverCreatedAtMs: 1_000), in: rawDB)
        }
        let removed = try db.writeSQL { rawDB in
            try TeamEventMirrorStore.deleteOlderThan(cutoffMs: 500, in: rawDB)
        }
        XCTAssertEqual(removed, 2)
        let remaining = try db.readSQL { rawDB in
            try TeamEventMirrorStore.readRecent(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(remaining.map { $0.eventID }, ["new1"])
    }
}
