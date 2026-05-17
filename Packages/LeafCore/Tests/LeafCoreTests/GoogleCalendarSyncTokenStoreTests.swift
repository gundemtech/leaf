import GRDB
import XCTest

@testable import LeafCore

/// Phase Track-6 P4 — `GoogleCalendarSyncTokenStore` ride atop existing
/// `provider_snapshots` (M015). Tests assert per-calendar isolation,
/// bootstrap flag transitions, and round-trip for the three snapshot_kinds
/// (`sync_token:events:<calendarId>`, `sync_token:calendar_list`, `known_calendars`).
final class GoogleCalendarSyncTokenStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gcal-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - 1. Fresh-DB initial state

    func testInitialStateReturnsNil() throws {
        let db = try openDB()
        let eventsCursor = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: raw)
        }
        let listCursor = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.calendarListSyncToken(in: raw)
        }
        let known = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.knownCalendars(in: raw)
        }
        XCTAssertNil(eventsCursor)
        XCTAssertNil(listCursor)
        XCTAssertEqual(known, [] as [GoogleCalendarSyncTokenStore.KnownCalendar])
    }

    // MARK: - 2. Events sync token round-trip

    func testUpsertEventsSyncTokenRoundTrip() throws {
        let db = try openDB()
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                calendarId: "primary",
                token: "tok_abc",
                lastFullSyncAtMs: 1_700_000_000_000,
                bootstrapInProgress: false,
                nowMs: 1_700_000_000_500,
                in: raw
            )
        }
        let cursor = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: raw)
        }
        XCTAssertEqual(cursor?.token, "tok_abc")
        XCTAssertEqual(cursor?.lastFullSyncAtMs, 1_700_000_000_000)
        XCTAssertEqual(cursor?.bootstrapInProgress, false)
    }

    // MARK: - 3. Multi-calendar isolation

    func testMultiCalendarIsolation() throws {
        let db = try openDB()
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                calendarId: "a",
                token: "tok_a",
                lastFullSyncAtMs: 100,
                bootstrapInProgress: false,
                nowMs: 100,
                in: raw
            )
            try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                calendarId: "b",
                token: "tok_b",
                lastFullSyncAtMs: 200,
                bootstrapInProgress: true,
                nowMs: 200,
                in: raw
            )
        }
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.deleteEventsSyncToken(calendarId: "a", in: raw)
        }
        let cursorA = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "a", in: raw)
        }
        let cursorB = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "b", in: raw)
        }
        XCTAssertNil(cursorA)
        XCTAssertEqual(cursorB?.token, "tok_b")
        XCTAssertEqual(cursorB?.bootstrapInProgress, true)
    }

    // MARK: - 4. Bootstrap flag transitions

    func testBootstrapFlagTransitions() throws {
        let db = try openDB()
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.markBootstrapInProgress(
                calendarId: "primary",
                nowMs: 100,
                in: raw
            )
        }
        var cursor = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: raw)
        }
        XCTAssertEqual(cursor?.bootstrapInProgress, true)
        XCTAssertNil(cursor?.token)

        // Subsequent upsert with bootstrapInProgress=false clears the flag.
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                calendarId: "primary",
                token: "tok_real",
                lastFullSyncAtMs: 500,
                bootstrapInProgress: false,
                nowMs: 500,
                in: raw
            )
        }
        cursor = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: raw)
        }
        XCTAssertEqual(cursor?.bootstrapInProgress, false)
        XCTAssertEqual(cursor?.token, "tok_real")
        XCTAssertEqual(cursor?.lastFullSyncAtMs, 500)
    }

    // MARK: - 5. Known-calendars array round-trip

    func testKnownCalendarsRoundTrip() throws {
        let db = try openDB()
        let cals: [GoogleCalendarSyncTokenStore.KnownCalendar] = [
            .init(
                id: "primary",
                summary: "demidov@example.com",
                summaryOverride: nil,
                accessRole: "owner",
                primary: true,
                colorId: "14",
                timeZone: "Europe/Belgrade"
            ),
            .init(
                id: "shared_team@group.calendar.google.com",
                summary: "Team",
                summaryOverride: "Team (work)",
                accessRole: "writer",
                primary: nil,
                colorId: nil,
                timeZone: "Europe/Belgrade"
            ),
        ]
        try db.writeSQL { raw in
            try GoogleCalendarSyncTokenStore.upsertKnownCalendars(cals, nowMs: 1_000, in: raw)
        }
        let readBack = try db.readSQL { raw in
            try GoogleCalendarSyncTokenStore.knownCalendars(in: raw)
        }
        XCTAssertEqual(readBack, cals)
    }
}
