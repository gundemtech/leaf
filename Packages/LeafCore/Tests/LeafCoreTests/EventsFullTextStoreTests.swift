// Phase Track-1 D2 — EventsFullTextStore body extraction + BM25 search.
//
// FTS5 contentless mode (`content = ''`) → indexed `body` not retrievable; UNINDEXED
// columns also empty on SELECT. Per-event verification therefore goes through the
// sidecar `events_fts_meta(fts_rowid, event_id, body_kind)` populated atomically
// by `EventsFullTextStore.indexEvent`. Body content is verified indirectly via
// `MATCH` queries (token presence implies indexing).
//
// Per-provider body-kind dispatch tests live in:
//   - EventsFullTextStoreLinearSlackTests.swift
//   - EventsFullTextStoreGitHubTests.swift
// This file retains the no-op + search ranking + period filter regression suite.

import GRDB
import XCTest

@testable import LeafCore

final class EventsFullTextStoreTests: XCTestCase {
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

    func testIndexEvent_NoBody_NoOp() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = ["event_kind": "issue_updated"]
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: "action", bundleID: "linear", payload: payload, in: rawDB
            )
        }
        XCTAssertEqual(try ftsMetaRowsForEvent(db, eventID: eid).count, 0)
    }

    func testSearch_BM25Ranking_OrdersByRelevance() throws {
        let db = try makeDB()
        let eHigh = try insertRawEventRow(db)
        let eMid = try insertRawEventRow(db)
        let eLow = try insertRawEventRow(db)

        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eHigh, signalType: "action", bundleID: "x",
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "auth auth auth filler filler",
                ],
                in: rawDB
            )
            try EventsFullTextStore.indexEvent(
                eventID: eMid, signalType: "action", bundleID: "x",
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "auth filler filler filler filler",
                ],
                in: rawDB
            )
            try EventsFullTextStore.indexEvent(
                eventID: eLow, signalType: "action", bundleID: "x",
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "auth filler filler filler filler filler filler filler filler filler",
                ],
                in: rawDB
            )
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let results: [Int64] = try db.readSQL { rawDB in
            try EventsFullTextStore.search(query: "auth", period: (now - 60_000)...(now + 60_000), limit: 10, in: rawDB)
        }
        XCTAssertEqual(
            results, [eHigh, eMid, eLow],
            "BM25 should order: high TF first, then short doc with TF=1, then long doc with TF=1")
    }

    func testSearch_PeriodFilterExcludesOutOfRange() throws {
        let db = try makeDB()
        let oldTs = Int64(Date().timeIntervalSince1970 * 1000) - 10 * 86_400_000
        let nowTs = Int64(Date().timeIntervalSince1970 * 1000)

        let eOld: Int64 = try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, 'action', 'x', '{}')",
                arguments: [oldTs]
            )
            return rawDB.lastInsertedRowID
        }
        let eNew: Int64 = try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, 'action', 'x', '{}')",
                arguments: [nowTs]
            )
            return rawDB.lastInsertedRowID
        }

        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eOld, signalType: "action", bundleID: "x",
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "matchword",
                ],
                in: rawDB
            )
            try EventsFullTextStore.indexEvent(
                eventID: eNew, signalType: "action", bundleID: "x",
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "matchword",
                ],
                in: rawDB
            )
        }

        let results: [Int64] = try db.readSQL { rawDB in
            try EventsFullTextStore.search(
                query: "matchword",
                period: (nowTs - 60_000)...(nowTs + 60_000),
                limit: 10, in: rawDB
            )
        }
        XCTAssertEqual(results, [eNew])
    }
}
