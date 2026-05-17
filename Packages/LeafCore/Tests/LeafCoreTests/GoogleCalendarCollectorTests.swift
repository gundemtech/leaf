// Track-6 P4 Task 13 — GoogleCalendarCollector bootstrap + steady-state tick.
// Scope: events.list pull → emit `google_calendar_event_observed` rows →
// persist syncToken only at terminal page. No transitions (Task 14),
// no presence_state writes (Task 16).
//
// Transition emission tests (Task 14, focusTime/OOO/workingLocation/cancelled/
// idempotency) live in GoogleCalendarCollectorTransitionTests.swift.
// presence_state composite snapshot writes (Task 16) live in
// GoogleCalendarCollectorPresenceStateTests.swift.
// Shared fixture helpers live in GoogleCalendarCollectorTestHelpers.swift.

import Foundation
import GRDB
import XCTest

@testable import LeafCore

final class GoogleCalendarCollectorTests: XCTestCase {
    private typealias Support = GoogleCalendarCollectorTestSupport

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gcal-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 1. Bootstrap path

    func testBootstrapPathCallsEventsListWithoutSyncToken() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        // NOTE: no events sync token row → bootstrap path.

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [Support.makeEvent(id: "evt-1")],
                nextPageToken: nil,
                nextSyncToken: "sync-1"
            ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: Support.makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 100
        )

        // calendarList piggy-back fires on first tick (counter=1 % N == 1).
        // Enqueue a calendarList response that re-includes 'primary' so the
        // diff doesn't drop our seeded calendar.
        await stub.enqueueCalendarList(
            GoogleCalendarAPI.CalendarListResponse(
                items: [
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "primary",
                        summary: "user@example.com",
                        summaryOverride: nil,
                        primary: true,
                        accessRole: "owner",
                        timeZone: "UTC",
                        colorId: nil
                    )
                ],
                nextPageToken: nil,
                nextSyncToken: "cal-list-sync-1"
            ))

        _ = try await collector.tick()

        let calls = await stub.calls()
        let eventsListCalls = calls.filter { $0.hasPrefix("eventsList") }
        XCTAssertEqual(eventsListCalls.count, 1, "expected exactly one eventsList call")
        // Bootstrap: syncToken=nil
        XCTAssertTrue(
            eventsListCalls[0].contains("syncToken=nil"),
            "bootstrap path must send syncToken=nil; got: \(eventsListCalls[0])")

        // syncToken persisted post-terminal-page.
        let cursor = try db.readSQL { rawDB in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: rawDB)
        }
        XCTAssertEqual(cursor?.token, "sync-1")
        XCTAssertFalse(cursor?.bootstrapInProgress ?? true)
    }

    // MARK: - 2. Subsequent path

    func testSubsequentTickUsesSavedSyncToken() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved-token-XYZ", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [], nextPageToken: nil, nextSyncToken: "sync-2"
            ))
        await stub.enqueueCalendarList(
            GoogleCalendarAPI.CalendarListResponse(
                items: [
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "primary", summary: nil, summaryOverride: nil,
                        primary: true, accessRole: "owner", timeZone: nil, colorId: nil
                    )
                ],
                nextPageToken: nil,
                nextSyncToken: nil
            ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: Support.makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        let calls = await stub.calls()
        let eventsListCalls = calls.filter { $0.hasPrefix("eventsList") }
        XCTAssertEqual(eventsListCalls.count, 1)
        XCTAssertTrue(
            eventsListCalls[0].contains("syncToken=saved-token-XYZ"),
            "subsequent tick must send saved sync token; got: \(eventsListCalls[0])")
    }

    // MARK: - 3. Pagination — sync token persisted only at terminal page

    func testPaginationWalksAllPagesBeforePersistingSyncToken() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "old-token", now: now)

        let stub = StubGoogleCalendarAPIClient()
        // Page 1: nextPageToken set, no nextSyncToken yet.
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [Support.makeEvent(id: "p1-a"), Support.makeEvent(id: "p1-b")],
                nextPageToken: "page-2",
                nextSyncToken: nil
            ))
        // Page 2 (terminal): nextSyncToken arrives here.
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [Support.makeEvent(id: "p2-a")],
                nextPageToken: nil,
                nextSyncToken: "sync-final"
            ))
        // Suppress calendarList (every-1 default on counter=1 ticks).
        await stub.enqueueCalendarList(
            GoogleCalendarAPI.CalendarListResponse(
                items: [
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "primary", summary: nil, summaryOverride: nil,
                        primary: true, accessRole: "owner", timeZone: nil, colorId: nil
                    )
                ],
                nextPageToken: nil, nextSyncToken: nil
            ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: Support.makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        // Both pages of events should have produced rows.
        let count = try Support.countObservedEvents(db)
        XCTAssertEqual(count, 3, "expected 3 observed events across 2 pages, got \(count)")

        // syncToken persisted = "sync-final" (terminal page only).
        let cursor = try db.readSQL { rawDB in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: rawDB)
        }
        XCTAssertEqual(
            cursor?.token, "sync-final",
            "syncToken must be persisted only when terminal page reached")
    }

    // MARK: - 4. Blocklist eventType filter

    func testBlocklistSkipsFromGmailAndBirthdayEvents() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [
                    Support.makeEvent(id: "real-1", eventType: "default"),
                    Support.makeEvent(id: "gmail-1", eventType: "fromGmail"),
                    Support.makeEvent(id: "bday-1", eventType: "birthday"),
                    Support.makeEvent(id: "real-2", eventType: "default"),
                ],
                nextPageToken: nil,
                nextSyncToken: "sync-after"
            ))
        await stub.enqueueCalendarList(
            GoogleCalendarAPI.CalendarListResponse(
                items: [
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "primary", summary: nil, summaryOverride: nil,
                        primary: true, accessRole: "owner", timeZone: nil, colorId: nil
                    )
                ],
                nextPageToken: nil, nextSyncToken: nil
            ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: Support.makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        // Only the 2 `default` events should make it to events table.
        let count = try Support.countObservedEvents(db)
        XCTAssertEqual(count, 2, "blocklist must filter fromGmail + birthday; got \(count) rows")

        // Privacy walkback: no row should mention `gmail-1` or `bday-1` ids.
        let payloads = try db.readSQL { rawDB in
            try String.fetchAll(rawDB, sql: "SELECT payload_json FROM events")
        }
        for p in payloads {
            XCTAssertFalse(p.contains("\"gmail-1\""), "blocklisted gmail event leaked: \(p)")
            XCTAssertFalse(p.contains("\"bday-1\""), "blocklisted birthday event leaked: \(p)")
        }
    }
}
