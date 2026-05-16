// Track-6 P4 Task 13 — GoogleCalendarCollector bootstrap + steady-state tick.
// Scope: events.list pull → emit `google_calendar_event_observed` rows →
// persist syncToken only at terminal page. No transitions (Task 14),
// no presence_state writes (Task 16).

import XCTest
import Foundation
import GRDB
@testable import LeafCore

private struct NoopGoogleOAuthHTTP: GoogleCalendarOAuthHTTP {
    func exchangeCode(
        code: String, codeVerifier: String, redirectURI: String,
        clientID: String, clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        fatalError("exchangeCode not used in collector tests")
    }

    func refreshToken(
        refreshToken: String, clientID: String, clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        fatalError("refresh not exercised in this task — TTL window deliberately far")
    }
}

final class GoogleCalendarCollectorTests: XCTestCase {
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

    // MARK: - Fixture helpers

    private func openDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest
        )
    }

    /// Seed an IntegrationRecord for `.googleCalendar` with a TTL well in the
    /// future so the proactive refresher returns `.notDue` and never hits the
    /// noop HTTP stub.
    private func seedIntegration(_ db: LeafCore.Database, now: Date) throws {
        let record = IntegrationRecord(
            provider: .googleCalendar,
            workspaceID: "user@example.com",
            workspaceName: "user@example.com",
            accessToken: "ya29.tok",
            refreshToken: "1//refresh-tok",
            expiresAt: now.addingTimeInterval(3600),  // 1h out — proactive refresher → .notDue
            scope: "https://www.googleapis.com/auth/calendar.readonly",
            connectedAt: now,
            updatedAt: now
        )
        try db.upsertIntegration(record)
    }

    private func seedKnownCalendar(_ db: LeafCore.Database, id: String, now: Date) throws {
        let known = GoogleCalendarSyncTokenStore.KnownCalendar(
            id: id,
            summary: id,
            summaryOverride: nil,
            accessRole: "owner",
            primary: id == "primary",
            colorId: nil,
            timeZone: "UTC"
        )
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.writeSQL { rawDB in
            try GoogleCalendarSyncTokenStore.upsertKnownCalendars([known], nowMs: nowMs, in: rawDB)
        }
    }

    private func seedEventsSyncToken(_ db: LeafCore.Database, calendarId: String, token: String, now: Date) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.writeSQL { rawDB in
            try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                calendarId: calendarId,
                token: token,
                lastFullSyncAtMs: nowMs,
                bootstrapInProgress: false,
                nowMs: nowMs,
                in: rawDB
            )
        }
    }

    private func makeRefresher() -> GoogleCalendarTokenRefresher {
        GoogleCalendarTokenRefresher(
            http: NoopGoogleOAuthHTTP(),
            clientID: "cid",
            clientSecret: "csec"
        )
    }

    private func makeEvent(
        id: String,
        eventType: String? = "default",
        status: String? = "confirmed"
    ) -> GoogleCalendarAPI.Event {
        // Build via JSON to avoid touching the (potentially-internal) memberwise init.
        var dict: [String: Any] = ["id": id]
        if let eventType { dict["eventType"] = eventType }
        if let status { dict["status"] = status }
        dict["summary"] = "evt-\(id)"
        dict["start"] = ["dateTime": "2026-01-15T10:00:00Z"]
        dict["end"] = ["dateTime": "2026-01-15T11:00:00Z"]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
    }

    private func makeEventsListResponse(
        items: [GoogleCalendarAPI.Event],
        nextPageToken: String? = nil,
        nextSyncToken: String? = nil
    ) -> GoogleCalendarAPI.EventsListResponse {
        GoogleCalendarAPI.EventsListResponse(
            kind: nil, summary: nil, timeZone: nil, accessRole: nil,
            items: items,
            nextPageToken: nextPageToken,
            nextSyncToken: nextSyncToken
        )
    }

    private func countObservedEvents(_ db: LeafCore.Database) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: """
                SELECT COUNT(*) FROM events
                 WHERE json_extract(payload_json, '$.event_kind') = 'google_calendar_event_observed'
                """) ?? 0
        }
    }

    // MARK: - 1. Bootstrap path

    func testBootstrapPathCallsEventsListWithoutSyncToken() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        // NOTE: no events sync token row → bootstrap path.

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(makeEventsListResponse(
            items: [makeEvent(id: "evt-1")],
            nextPageToken: nil,
            nextSyncToken: "sync-1"
        ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 100   // suppress calendarList on first tick (1 % 100 == 1 normally; bump high so it would still fire on tickCounter=1; use 100 to ensure 1%100==1 — actually need to suppress; instead enqueue a calendarList response below)
        )

        // calendarList piggy-back fires on first tick (counter=1 % N == 1).
        // Enqueue an empty response so the collector keeps `known_calendars`
        // as we seeded it (empty result + diff drops our seeded calendar!).
        // Simpler: enqueue a calendarList response that re-includes 'primary'.
        await stub.enqueueCalendarList(GoogleCalendarAPI.CalendarListResponse(
            items: [GoogleCalendarAPI.CalendarListEntry(
                id: "primary",
                summary: "user@example.com",
                summaryOverride: nil,
                primary: true,
                accessRole: "owner",
                timeZone: "UTC",
                colorId: nil
            )],
            nextPageToken: nil,
            nextSyncToken: "cal-list-sync-1"
        ))

        _ = try await collector.tick()

        let calls = await stub.calls()
        let eventsListCalls = calls.filter { $0.hasPrefix("eventsList") }
        XCTAssertEqual(eventsListCalls.count, 1, "expected exactly one eventsList call")
        // Bootstrap: syncToken=nil
        XCTAssertTrue(eventsListCalls[0].contains("syncToken=nil"),
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
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved-token-XYZ", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(makeEventsListResponse(
            items: [], nextPageToken: nil, nextSyncToken: "sync-2"
        ))
        await stub.enqueueCalendarList(GoogleCalendarAPI.CalendarListResponse(
            items: [GoogleCalendarAPI.CalendarListEntry(
                id: "primary", summary: nil, summaryOverride: nil,
                primary: true, accessRole: "owner", timeZone: nil, colorId: nil
            )],
            nextPageToken: nil,
            nextSyncToken: nil
        ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        let calls = await stub.calls()
        let eventsListCalls = calls.filter { $0.hasPrefix("eventsList") }
        XCTAssertEqual(eventsListCalls.count, 1)
        XCTAssertTrue(eventsListCalls[0].contains("syncToken=saved-token-XYZ"),
                      "subsequent tick must send saved sync token; got: \(eventsListCalls[0])")
    }

    // MARK: - 3. Pagination — sync token persisted only at terminal page

    func testPaginationWalksAllPagesBeforePersistingSyncToken() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "old-token", now: now)

        let stub = StubGoogleCalendarAPIClient()
        // Page 1: nextPageToken set, no nextSyncToken yet.
        await stub.enqueueEventsList(makeEventsListResponse(
            items: [makeEvent(id: "p1-a"), makeEvent(id: "p1-b")],
            nextPageToken: "page-2",
            nextSyncToken: nil
        ))
        // Page 2 (terminal): nextSyncToken arrives here.
        await stub.enqueueEventsList(makeEventsListResponse(
            items: [makeEvent(id: "p2-a")],
            nextPageToken: nil,
            nextSyncToken: "sync-final"
        ))
        // Suppress calendarList (every-1 default on counter=1 ticks).
        await stub.enqueueCalendarList(GoogleCalendarAPI.CalendarListResponse(
            items: [GoogleCalendarAPI.CalendarListEntry(
                id: "primary", summary: nil, summaryOverride: nil,
                primary: true, accessRole: "owner", timeZone: nil, colorId: nil
            )],
            nextPageToken: nil, nextSyncToken: nil
        ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        // Both pages of events should have produced rows.
        let count = try countObservedEvents(db)
        XCTAssertEqual(count, 3, "expected 3 observed events across 2 pages, got \(count)")

        // syncToken persisted = "sync-final" (terminal page only).
        let cursor = try db.readSQL { rawDB in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: "primary", in: rawDB)
        }
        XCTAssertEqual(cursor?.token, "sync-final",
                       "syncToken must be persisted only when terminal page reached")
    }

    // MARK: - 4. Blocklist eventType filter

    func testBlocklistSkipsFromGmailAndBirthdayEvents() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(makeEventsListResponse(
            items: [
                makeEvent(id: "real-1", eventType: "default"),
                makeEvent(id: "gmail-1", eventType: "fromGmail"),
                makeEvent(id: "bday-1", eventType: "birthday"),
                makeEvent(id: "real-2", eventType: "default")
            ],
            nextPageToken: nil,
            nextSyncToken: "sync-after"
        ))
        await stub.enqueueCalendarList(GoogleCalendarAPI.CalendarListResponse(
            items: [GoogleCalendarAPI.CalendarListEntry(
                id: "primary", summary: nil, summaryOverride: nil,
                primary: true, accessRole: "owner", timeZone: nil, colorId: nil
            )],
            nextPageToken: nil, nextSyncToken: nil
        ))

        let collector = GoogleCalendarCollector(
            apiClient: stub,
            tokenRefresher: makeRefresher(),
            database: db,
            clock: { now },
            pollIntervalSec: 300,
            calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()

        // Only the 2 `default` events should make it to events table.
        let count = try countObservedEvents(db)
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
