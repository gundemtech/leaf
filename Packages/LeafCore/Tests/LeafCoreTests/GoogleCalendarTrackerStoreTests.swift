// Phase Track-6 P4 Task 5 — GoogleCalendarTrackerStore CRUD + scan + cleanup.
// Mirrors IntensityAggregatesStoreTests pattern (real Database open with
// deterministicTest encryption + writeSQL/readSQL handles).

import XCTest
import GRDB
@testable import LeafCore

final class GoogleCalendarTrackerStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gcal-tracker-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - 1. UPSERT insert

    func testUpsertFocusTimeRowInserts() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: "evt-focus-1",
                calendarID: "primary",
                iCalUID: "ical-abc",
                eventType: "focusTime",
                startMs: 1_000,
                endMs: 2_000,
                workingLocationType: nil,
                autoDeclineMode: nil,
                chatStatus: nil,
                upsertedAtMs: 500,
                in: rawDB
            )
        }
        try db.readSQL { rawDB in
            let rows = try GoogleCalendarTrackerStore.rowsNeedingStartedEmit(now: 1_500, in: rawDB)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].eventID, "evt-focus-1")
            XCTAssertEqual(rows[0].calendarID, "primary")
            XCTAssertEqual(rows[0].iCalUID, "ical-abc")
            XCTAssertEqual(rows[0].eventType, "focusTime")
            XCTAssertEqual(rows[0].startMs, 1_000)
            XCTAssertEqual(rows[0].endMs, 2_000)
            XCTAssertNil(rows[0].startedEmittedAtMs)
            XCTAssertNil(rows[0].endedEmittedAtMs)
            XCTAssertEqual(rows[0].upsertedAtMs, 500)
        }
    }

    // MARK: - 2. UPSERT preserves emitted flags

    func testUpsertSameEventIDUpdatesEndMsPreservingEmittedFlags() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: "evt-1", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 1_000, endMs: 2_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 500, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "evt-1", atMs: 1_100, in: rawDB)
            // Server pushes end_ms extension; UPSERT must not clobber emitted flag.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "evt-1", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 1_000, endMs: 3_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 1_200, in: rawDB
            )
        }
        try db.readSQL { rawDB in
            let row = try Row.fetchOne(
                rawDB,
                sql: """
                    SELECT end_ms, started_emitted_at_ms, ended_emitted_at_ms, upserted_at_ms
                      FROM google_calendar_typed_event_tracker WHERE event_id = 'evt-1'
                    """
            )
            XCTAssertEqual(row?["end_ms"] as Int64?, 3_000)
            XCTAssertEqual(row?["started_emitted_at_ms"] as Int64?, 1_100, "started flag preserved on UPSERT")
            XCTAssertNil(row?["ended_emitted_at_ms"] as Int64?)
            XCTAssertEqual(row?["upserted_at_ms"] as Int64?, 1_200)
        }
    }

    // MARK: - 3. rowsNeedingStartedEmit filter

    func testRowsNeedingStartedEmitFiltersCorrectly() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // Row A: start in the past, not yet emitted — should appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "A", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 1_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            // Row B: start in the future — must NOT appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "B", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 5_000, endMs: 6_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            // Row C: already emitted — must NOT appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "C", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 200, endMs: 1_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "C", atMs: 250, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try GoogleCalendarTrackerStore.rowsNeedingStartedEmit(now: 1_000, in: rawDB)
            XCTAssertEqual(rows.map { $0.eventID }, ["A"])
        }
    }

    // MARK: - 4. markStartedEmitted

    func testMarkStartedEmittedSetsTimestamp() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: "evt", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 1_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "evt", atMs: 150, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try GoogleCalendarTrackerStore.rowsNeedingStartedEmit(now: 5_000, in: rawDB)
            XCTAssertTrue(rows.isEmpty, "row no longer pending after mark")
            let stored = try Int64.fetchOne(
                rawDB,
                sql: "SELECT started_emitted_at_ms FROM google_calendar_typed_event_tracker WHERE event_id = ?",
                arguments: ["evt"]
            )
            XCTAssertEqual(stored, 150)
        }
    }

    // MARK: - 5. rowsNeedingEndedEmit filter

    func testRowsNeedingEndedEmitFiltersCorrectly() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // Row A: ended-due + started_emitted — should appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "A", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "A", atMs: 110, in: rawDB)
            // Row B: ended-due BUT not yet started_emitted — must NOT appear (we never emitted _started, so no _ended either).
            try GoogleCalendarTrackerStore.upsert(
                eventID: "B", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            // Row C: started_emitted, end in future — must NOT appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "C", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 5_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "C", atMs: 110, in: rawDB)
            // Row D: started_emitted + ended_emitted already — must NOT appear.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "D", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "D", atMs: 110, in: rawDB)
            try GoogleCalendarTrackerStore.markEndedEmitted(eventID: "D", atMs: 210, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try GoogleCalendarTrackerStore.rowsNeedingEndedEmit(now: 1_000, in: rawDB)
            XCTAssertEqual(rows.map { $0.eventID }, ["A"])
        }
    }

    // MARK: - 6. rowsNeedingEndedEmit excludes workingLocation

    func testRowsNeedingEndedEmitExcludesWorkingLocation() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // workingLocation row: started_emitted true, end in past. Should NOT appear in ended-scan.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "wl", calendarID: "primary", iCalUID: nil,
                eventType: "workingLocation", startMs: 100, endMs: 200,
                workingLocationType: "homeOffice", autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "wl", atMs: 110, in: rawDB)
            // focusTime control row that DOES need _ended.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "ft", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.markStartedEmitted(eventID: "ft", atMs: 110, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try GoogleCalendarTrackerStore.rowsNeedingEndedEmit(now: 1_000, in: rawDB)
            XCTAssertEqual(rows.map { $0.eventID }, ["ft"],
                           "workingLocation rows are single-shot — never need _ended emission")
        }
    }

    // MARK: - 7. deleteByCalendarID

    func testDeleteByCalendarIDScopesCorrectly() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: "a1", calendarID: "calA", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.upsert(
                eventID: "a2", calendarID: "calA", iCalUID: nil,
                eventType: "outOfOffice", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.upsert(
                eventID: "b1", calendarID: "calB", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.deleteByCalendarID("calA", in: rawDB)
        }
        try db.readSQL { rawDB in
            let ids = try String.fetchAll(
                rawDB,
                sql: "SELECT event_id FROM google_calendar_typed_event_tracker ORDER BY event_id"
            )
            XCTAssertEqual(ids, ["b1"])
        }
    }

    // MARK: - 8. delete by eventID

    func testDeleteByEventIDRemovesOneRow() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: "x", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.upsert(
                eventID: "y", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 100, endMs: 200,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            try GoogleCalendarTrackerStore.delete(eventID: "x", in: rawDB)
        }
        try db.readSQL { rawDB in
            let ids = try String.fetchAll(
                rawDB,
                sql: "SELECT event_id FROM google_calendar_typed_event_tracker ORDER BY event_id"
            )
            XCTAssertEqual(ids, ["y"])
        }
    }

    // MARK: - 9. cleanup

    func testCleanupDropsRowsOlderThan() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // end_ms = 100 — should be cleaned (< cutoff 500).
            try GoogleCalendarTrackerStore.upsert(
                eventID: "old", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 10, endMs: 100,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 5, in: rawDB
            )
            // end_ms = 500 — boundary, retained (NOT strictly less than cutoff).
            try GoogleCalendarTrackerStore.upsert(
                eventID: "edge", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 400, endMs: 500,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 5, in: rawDB
            )
            // end_ms = 1000 — retained.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "new", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 800, endMs: 1_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 5, in: rawDB
            )
            try GoogleCalendarTrackerStore.cleanup(beforeMs: 500, in: rawDB)
        }
        try db.readSQL { rawDB in
            let ids = try String.fetchAll(
                rawDB,
                sql: "SELECT event_id FROM google_calendar_typed_event_tracker ORDER BY event_id"
            )
            XCTAssertEqual(ids, ["edge", "new"])
        }
    }

    // MARK: - 10. presence-state queries

    func testHasActiveFocusBlockAndOOOAndCurrentWorkingLocationReflectState() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // Focus block active at now=1500 (start 1000, end 2000).
            try GoogleCalendarTrackerStore.upsert(
                eventID: "fb", calendarID: "primary", iCalUID: nil,
                eventType: "focusTime", startMs: 1_000, endMs: 2_000,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            // OOO active at now=1500.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "ooo", calendarID: "primary", iCalUID: nil,
                eventType: "outOfOffice", startMs: 1_200, endMs: 1_800,
                workingLocationType: nil, autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 10, in: rawDB
            )
            // workingLocation: two rows, picking most recent start covering now.
            try GoogleCalendarTrackerStore.upsert(
                eventID: "wl-old", calendarID: "primary", iCalUID: nil,
                eventType: "workingLocation", startMs: 500, endMs: 5_000,
                workingLocationType: "officeLocation", autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 5, in: rawDB
            )
            try GoogleCalendarTrackerStore.upsert(
                eventID: "wl-new", calendarID: "primary", iCalUID: nil,
                eventType: "workingLocation", startMs: 1_400, endMs: 3_000,
                workingLocationType: "homeOffice", autoDeclineMode: nil, chatStatus: nil, upsertedAtMs: 6, in: rawDB
            )
        }
        try db.readSQL { rawDB in
            XCTAssertTrue(try GoogleCalendarTrackerStore.hasActiveFocusBlock(now: 1_500, in: rawDB))
            XCTAssertFalse(try GoogleCalendarTrackerStore.hasActiveFocusBlock(now: 2_500, in: rawDB),
                           "after end_ms boundary, no longer active")
            XCTAssertTrue(try GoogleCalendarTrackerStore.hasActiveOOO(now: 1_500, in: rawDB))
            XCTAssertFalse(try GoogleCalendarTrackerStore.hasActiveOOO(now: 100, in: rawDB))
            XCTAssertEqual(
                try GoogleCalendarTrackerStore.currentWorkingLocation(now: 1_500, in: rawDB),
                "homeOffice",
                "most recent start covering `now` wins"
            )
            XCTAssertEqual(
                try GoogleCalendarTrackerStore.currentWorkingLocation(now: 1_000, in: rawDB),
                "officeLocation",
                "before wl-new starts, the older overlapping row is current"
            )
            XCTAssertNil(
                try GoogleCalendarTrackerStore.currentWorkingLocation(now: 10_000, in: rawDB),
                "no working location after all rows end"
            )
        }
    }
}
