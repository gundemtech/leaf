// Phase Track-1 D2 — EventLinksStore derivation + reader API (public substrate).

import GRDB
import XCTest

@testable import LeafCore

final class EventLinksStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func insertRawEventRow(_ db: LeafCore.Database, ts: Int64? = nil) throws -> Int64 {
        let tsMs = ts ?? Int64(Date().timeIntervalSince1970 * 1000)
        return try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, 'action', 'x', '{}')",
                arguments: [tsMs]
            )
            return rawDB.lastInsertedRowID
        }
    }

    private func linksForEvent(_ db: LeafCore.Database, eventID: Int64) throws -> [EventLink] {
        try db.readSQL { rawDB in
            try EventLinksStore.linksFrom(eventID: eventID, in: rawDB)
        }
    }

    private func derive(
        _ db: LeafCore.Database, eventID: Int64, ts: Int64, payload: [String: String], prefixes: Set<String>
    ) throws {
        try db.writeSQL { rawDB in
            try EventLinksStore.deriveLinks(
                eventID: eventID, ts: ts, payload: payload,
                knownLinearPrefixes: prefixes,
                derivers: .publicSubstrate,
                in: rawDB
            )
        }
    }

    func testDeriveLinks_LinearIDInText_Match() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(
            db, eventID: eid, ts: 1_000,
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "Working on LEAF-127",
            ],
            prefixes: ["LEAF"])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].linkKind, Schema.LinkKinds.linearIDInText)
        XCTAssertEqual(rows[0].targetKind, Schema.TargetKinds.linearIssue)
        XCTAssertEqual(rows[0].targetRef, "LEAF-127")
        XCTAssertGreaterThan(rows[0].confidence, 0.0)
        XCTAssertLessThanOrEqual(rows[0].confidence, 1.0)
    }

    func testDeriveLinks_LinearIDInText_AllMatches() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(
            db, eventID: eid, ts: 1_000,
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "fixes LEAF-127 and LEAF-200",
            ],
            prefixes: ["LEAF"])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map { $0.targetRef }), Set(["LEAF-127", "LEAF-200"]))
    }

    func testDeriveLinks_LinearIDInText_UnknownPrefixIgnored() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(
            db, eventID: eid, ts: 1_000,
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "BAD-99 should be ignored",
            ],
            prefixes: ["LEAF"])
        XCTAssertEqual(try linksForEvent(db, eventID: eid).count, 0)
    }

    func testDeriveLinks_RequestedReviewers_FanOut() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(
            db, eventID: eid, ts: 1_000,
            payload: [
                "event_kind": "gh_pr_opened",
                Schema.EventPayloadKeys.requestedReviewersJson: #"["alice","bob"]"#,
            ],
            prefixes: [])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.linkKind == Schema.LinkKinds.reviewerAssigned })
        XCTAssertTrue(rows.allSatisfy { $0.targetKind == Schema.TargetKinds.githubUser })
        XCTAssertEqual(Set(rows.map { $0.targetRef }), Set(["alice", "bob"]))
    }

    func testDeriveLinks_NoBody_NoOp() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(
            db, eventID: eid, ts: 1_000,
            payload: ["event_kind": "issue_updated"],
            prefixes: ["LEAF"])
        XCTAssertEqual(try linksForEvent(db, eventID: eid).count, 0)
    }

    func testDeriveLinks_DuplicateInsertIgnored() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload = [
            "event_kind": "issue_updated",
            Schema.EventPayloadKeys.body: "LEAF-127 again",
        ]
        try derive(db, eventID: eid, ts: 1_000, payload: payload, prefixes: ["LEAF"])
        try derive(db, eventID: eid, ts: 2_000, payload: payload, prefixes: ["LEAF"])
        XCTAssertEqual(try linksForEvent(db, eventID: eid).count, 1)
    }

    func testEventsLinkingTo_FiltersByPeriod() throws {
        let db = try makeDB()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldMs = nowMs - 10 * 86_400_000  // 10 days ago

        let eOld = try insertRawEventRow(db, ts: oldMs)
        let eNew = try insertRawEventRow(db, ts: nowMs)
        let payload = [
            "event_kind": "issue_updated",
            Schema.EventPayloadKeys.body: "fix LEAF-127",
        ]
        try derive(db, eventID: eOld, ts: oldMs, payload: payload, prefixes: ["LEAF"])
        try derive(db, eventID: eNew, ts: nowMs, payload: payload, prefixes: ["LEAF"])

        // Narrow window covering only "now".
        let recent: [Int64] = try db.readSQL { rawDB in
            try EventLinksStore.eventsLinkingTo(
                targetKind: Schema.TargetKinds.linearIssue,
                targetRef: "LEAF-127",
                period: (nowMs - 60_000)...(nowMs + 60_000),
                in: rawDB
            )
        }
        XCTAssertEqual(recent, [eNew])

        // No period — both rows.
        let all: [Int64] = try db.readSQL { rawDB in
            try EventLinksStore.eventsLinkingTo(
                targetKind: Schema.TargetKinds.linearIssue,
                targetRef: "LEAF-127",
                period: nil,
                in: rawDB
            )
        }
        XCTAssertEqual(Set(all), Set([eOld, eNew]))
    }

    func testEventsLinkingTo_NoPeriod_ReturnsNewestFirst() throws {
        let db = try makeDB()
        let baseMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Insert 5 events with distinct, increasing ts, all linking to the same Linear ID.
        var insertedEventIDs: [Int64] = []
        for i in 0..<5 {
            let ts = baseMs + Int64(i * 1000)
            let eid = try insertRawEventRow(db, ts: ts)
            insertedEventIDs.append(eid)
            try derive(
                db, eventID: eid, ts: ts,
                payload: [
                    "event_kind": "issue_updated",
                    Schema.EventPayloadKeys.body: "fix LEAF-127",
                ],
                prefixes: ["LEAF"])
        }

        // No-period branch: must return newest-first (LIMIT 200 keeps newest, not oldest).
        let result: [Int64] = try db.readSQL { rawDB in
            try EventLinksStore.eventsLinkingTo(
                targetKind: Schema.TargetKinds.linearIssue,
                targetRef: "LEAF-127",
                period: nil,
                in: rawDB
            )
        }
        XCTAssertEqual(
            result, insertedEventIDs.reversed(),
            "No-period branch must return events ordered newest-first by ts (LIMIT semantics)")
    }
}
