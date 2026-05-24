// Phase Track-6 P5 — EventLinksStore.deriveLinks branch for zoom_meeting_started
// payloads carrying linked_calendar_event_id. Independent test file to keep P5
// changes localized; pattern follows EventLinksStoreTests.swift verbatim.

import XCTest
import GRDB
@testable import LeafCore

final class EventLinksStoreZoomTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-zoom-links-\(UUID().uuidString)", isDirectory: true)
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
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, 'context', 'us.zoom.xos', '{}')",
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

    private func derive(_ db: LeafCore.Database, eventID: Int64, ts: Int64, payload: [String: String]) throws {
        try db.writeSQL { rawDB in
            try EventLinksStore.deriveLinks(
                eventID: eventID, ts: ts, payload: payload,
                knownLinearPrefixes: [],
                derivers: .publicSubstrate,
                in: rawDB
            )
        }
    }

    func testZoomStartedWithLinkedIDWritesRow() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(db, eventID: eid, ts: 1_000_000,
                   payload: ["event_kind": "zoom_meeting_started",
                             Schema.EventPayloadKeys.linkedCalendarEventID: "deadbeefcafef00d"])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].linkKind, Schema.LinkKinds.zoomToCalendarMeeting)
        XCTAssertEqual(rows[0].targetKind, Schema.TargetKinds.calendarEvent)
        XCTAssertEqual(rows[0].targetRef, "deadbeefcafef00d")
        XCTAssertGreaterThan(rows[0].confidence, 0.5)  // 0.95 public default
    }

    func testZoomStartedWithEmptyLinkedIDNoRow() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(db, eventID: eid, ts: 1_000_000,
                   payload: ["event_kind": "zoom_meeting_started",
                             Schema.EventPayloadKeys.linkedCalendarEventID: ""])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 0)
    }

    func testZoomStartedWithoutLinkedIDFieldNoRow() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(db, eventID: eid, ts: 1_000_000,
                   payload: ["event_kind": "zoom_meeting_started"])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 0)
    }

    func testNonZoomKindWithLinkedIDFieldIgnored() throws {
        // Defense: only zoom_meeting_started consumes the linked_calendar_event_id field.
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(db, eventID: eid, ts: 1_000_000,
                   payload: ["event_kind": "zoom_meeting_ended",  // wrong kind
                             Schema.EventPayloadKeys.linkedCalendarEventID: "ababababcdcdcdcd"])
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 0)
    }

    func testDeriveIdempotentOnRepeat() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        let payload: [String: String] = ["event_kind": "zoom_meeting_started",
                                          Schema.EventPayloadKeys.linkedCalendarEventID: "abc123def456"]
        for _ in 0..<3 {
            try derive(db, eventID: eid, ts: 1_000_000, payload: payload)
        }
        let rows = try linksForEvent(db, eventID: eid)
        XCTAssertEqual(rows.count, 1, "INSERT OR IGNORE should dedupe via composite PK")
    }

    func testReverseLookupReturnsZoomEvent() throws {
        let db = try makeDB()
        let eid = try insertRawEventRow(db)
        try derive(db, eventID: eid, ts: 1_000_000,
                   payload: ["event_kind": "zoom_meeting_started",
                             Schema.EventPayloadKeys.linkedCalendarEventID: "lookuphash000000"])
        let found = try db.readSQL { rawDB in
            try EventLinksStore.eventsLinkingTo(
                targetKind: Schema.TargetKinds.calendarEvent,
                targetRef: "lookuphash000000",
                period: nil,
                in: rawDB
            )
        }
        XCTAssertEqual(found, [eid])
    }
}
