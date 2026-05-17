// Track-6 P4 Task 13 — GoogleCalendarCollector bootstrap + steady-state tick.
// Scope: events.list pull → emit `google_calendar_event_observed` rows →
// persist syncToken only at terminal page. No transitions (Task 14),
// no presence_state writes (Task 16).

import Foundation
import GRDB
import XCTest

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
        // swiftlint:disable force_try -- test fixture; dict is hand-built JSON-compatible payload
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
        // swiftlint:enable force_try
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
            try Int.fetchOne(
                rawDB,
                sql: """
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
        await stub.enqueueEventsList(
            makeEventsListResponse(
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
            calendarListEveryNTicks: 100  // suppress calendarList on first tick (1 % 100 == 1 normally; bump high so it would still fire on tickCounter=1; use 100 to ensure 1%100==1 — actually need to suppress; instead enqueue a calendarList response below)
        )

        // calendarList piggy-back fires on first tick (counter=1 % N == 1).
        // Enqueue an empty response so the collector keeps `known_calendars`
        // as we seeded it (empty result + diff drops our seeded calendar!).
        // Simpler: enqueue a calendarList response that re-includes 'primary'.
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
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved-token-XYZ", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            makeEventsListResponse(
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
        XCTAssertTrue(
            eventsListCalls[0].contains("syncToken=saved-token-XYZ"),
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
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [makeEvent(id: "p1-a"), makeEvent(id: "p1-b")],
                nextPageToken: "page-2",
                nextSyncToken: nil
            ))
        // Page 2 (terminal): nextSyncToken arrives here.
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [makeEvent(id: "p2-a")],
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
        XCTAssertEqual(
            cursor?.token, "sync-final",
            "syncToken must be persisted only when terminal page reached")
    }

    // MARK: - Task 14 helpers

    /// Stub `eventsList` + `calendarList` responses so the tick advances past
    /// its API steps with no per-tick events, leaving only the transition-scan
    /// phase to exercise. Tracker rows are seeded directly by the test body.
    private func enqueueEmptyAPIResponses(_ stub: StubGoogleCalendarAPIClient) async {
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [], nextPageToken: nil, nextSyncToken: "tick-sync"
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
    }

    /// Direct tracker seed bypassing the collector's per-event UPSERT path,
    /// so each test owns its tracker fixture without juggling typed-property
    /// JSON shapes through events.list.
    private func seedTrackerRow(
        _ db: LeafCore.Database,
        eventID: String,
        eventType: String,
        startMs: Int64,
        endMs: Int64,
        startedEmittedAtMs: Int64? = nil,
        workingLocationType: String? = nil,
        autoDeclineMode: String? = nil,
        chatStatus: String? = nil,
        now: Date
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.writeSQL { rawDB in
            try GoogleCalendarTrackerStore.upsert(
                eventID: eventID,
                calendarID: "primary",
                iCalUID: "ical-\(eventID)",
                eventType: eventType,
                startMs: startMs,
                endMs: endMs,
                workingLocationType: workingLocationType,
                autoDeclineMode: autoDeclineMode,
                chatStatus: chatStatus,
                upsertedAtMs: nowMs,
                in: rawDB
            )
            if let mark = startedEmittedAtMs {
                try GoogleCalendarTrackerStore.markStartedEmitted(
                    eventID: eventID, atMs: mark, in: rawDB
                )
            }
        }
    }

    private func countTransitionEvents(_ db: LeafCore.Database, kind: String) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(
                rawDB,
                sql: """
                    SELECT COUNT(*) FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [kind]) ?? 0
        }
    }

    private func transitionPayloads(_ db: LeafCore.Database, kind: String) throws -> [String] {
        try db.readSQL { rawDB in
            try String.fetchAll(
                rawDB,
                sql: """
                    SELECT payload_json FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [kind])
        }
    }

    // MARK: - 5. focusTime → started transition

    func testFocusTimeCrossingStartMsEmitsStartedTransition() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active focus block: started 1 min ago, ends in 4 min.
        try seedTrackerRow(
            db,
            eventID: "ft-1",
            eventType: "focusTime",
            startMs: nowMs - 60_000,
            endMs: nowMs + 4 * 60_000,
            autoDeclineMode: "declineOnlyNewConflictingInvitations",
            chatStatus: "doNotDisturb",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        XCTAssertEqual(try countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 1)
        let payloads = try transitionPayloads(db, kind: "google_calendar_focus_block_started")
        XCTAssertTrue(payloads[0].contains("\"event_id\":\"ft-1\""), "payload missing event_id: \(payloads[0])")
        XCTAssertTrue(
            payloads[0].contains("declineOnlyNewConflictingInvitations"),
            "auto_decline_mode bucket missing on _started: \(payloads[0])")
        XCTAssertTrue(
            payloads[0].contains("doNotDisturb"),
            "chat_status bucket missing on _started: \(payloads[0])")

        // Tracker flag flipped.
        let flag = try db.readSQL { rawDB in
            try Int64.fetchOne(
                rawDB,
                sql: "SELECT started_emitted_at_ms FROM google_calendar_typed_event_tracker WHERE event_id = ?",
                arguments: ["ft-1"]
            )
        }
        XCTAssertNotNil(flag, "started_emitted_at_ms must be set after emission")
    }

    // MARK: - 6. focusTime → ended transition (no active-phase metadata)

    func testFocusTimeCrossingEndMsEmitsEndedTransition() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Block already ended (end 1 min ago) and _started was emitted previously.
        try seedTrackerRow(
            db,
            eventID: "ft-2",
            eventType: "focusTime",
            startMs: nowMs - 5 * 60_000,
            endMs: nowMs - 60_000,
            startedEmittedAtMs: nowMs - 4 * 60_000,
            autoDeclineMode: "declineAllConflictingInvitations",
            chatStatus: "doNotDisturb",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        XCTAssertEqual(try countTransitionEvents(db, kind: "google_calendar_focus_block_ended"), 1)
        let payloads = try transitionPayloads(db, kind: "google_calendar_focus_block_ended")
        XCTAssertTrue(payloads[0].contains("\"event_id\":\"ft-2\""))
        XCTAssertFalse(
            payloads[0].contains("auto_decline_mode"),
            "auto_decline_mode must NOT appear on _ended: \(payloads[0])")
        XCTAssertFalse(
            payloads[0].contains("chat_status"),
            "chat_status must NOT appear on _ended: \(payloads[0])")
        // _started must NOT also emit (already marked).
        XCTAssertEqual(try countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 0)
    }

    // MARK: - 7. outOfOffice — autoDeclineMode on started, not on ended

    func testOOOTransitionEmitsAutoDeclineModeOnStartedNotOnEnded() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active OOO — _started not yet emitted.
        try seedTrackerRow(
            db,
            eventID: "ooo-active",
            eventType: "outOfOffice",
            startMs: nowMs - 60_000,
            endMs: nowMs + 4 * 60_000,
            autoDeclineMode: "declineAllConflictingInvitations",
            now: now
        )
        // Already-ended OOO — _started was emitted, now needs _ended.
        try seedTrackerRow(
            db,
            eventID: "ooo-done",
            eventType: "outOfOffice",
            startMs: nowMs - 5 * 60_000,
            endMs: nowMs - 60_000,
            startedEmittedAtMs: nowMs - 4 * 60_000,
            autoDeclineMode: "declineAllConflictingInvitations",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        // _started emitted for ooo-active.
        let started = try transitionPayloads(db, kind: "google_calendar_ooo_started")
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started[0].contains("\"event_id\":\"ooo-active\""))
        XCTAssertTrue(
            started[0].contains("declineAllConflictingInvitations"),
            "auto_decline_mode must appear on OOO _started")
        XCTAssertFalse(
            started[0].contains("chat_status"),
            "chat_status is focusTime-only — must NOT appear on OOO")

        // _ended emitted for ooo-done, without auto_decline_mode.
        let ended = try transitionPayloads(db, kind: "google_calendar_ooo_ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(ended[0].contains("\"event_id\":\"ooo-done\""))
        XCTAssertFalse(
            ended[0].contains("auto_decline_mode"),
            "auto_decline_mode must NOT appear on _ended")
    }

    // MARK: - 8. workingLocation single-shot _changed + idempotent on re-tick

    func testWorkingLocationCrossingStartMsEmitsChangedOnce() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        try seedTrackerRow(
            db,
            eventID: "wl-1",
            eventType: "workingLocation",
            startMs: nowMs - 30 * 60_000,
            endMs: nowMs + 8 * 3600 * 1000,
            workingLocationType: "homeOffice",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        // Two ticks → two API enqueues.
        await enqueueEmptyAPIResponses(stub)
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()
        _ = try await collector.tick()  // idempotency re-tick

        XCTAssertEqual(
            try countTransitionEvents(db, kind: "google_calendar_working_location_changed"), 1,
            "workingLocation must emit _changed exactly once across re-ticks")
        let payloads = try transitionPayloads(db, kind: "google_calendar_working_location_changed")
        XCTAssertTrue(payloads[0].contains("\"working_location_type\":\"homeOffice\""))
        // Single-shot — paired _ended must never appear.
        XCTAssertEqual(try countTransitionEvents(db, kind: "google_calendar_working_location_ended"), 0)
    }

    // MARK: - 9. cancelled event — tracker delete suppresses transition

    func testCancelledEventDoesNotEmitTransition() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Pre-seed a tracker row that the cancelled event will tombstone.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedTrackerRow(
            db,
            eventID: "ft-cancel",
            eventType: "focusTime",
            startMs: nowMs - 60_000,
            endMs: nowMs + 4 * 60_000,
            autoDeclineMode: "declineOnlyNewConflictingInvitations",
            chatStatus: "doNotDisturb",
            now: now
        )

        // events.list returns a cancellation tombstone for ft-cancel.
        let dict: [String: Any] = [
            "id": "ft-cancel",
            "status": "cancelled",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let cancelEvent = try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [cancelEvent], nextPageToken: nil, nextSyncToken: "sync-after-cancel"
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
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        // No transition emitted; tracker row removed.
        XCTAssertEqual(try countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 0)
        let trackerCount = try db.readSQL { rawDB in
            try Int.fetchOne(
                rawDB,
                sql: """
                    SELECT COUNT(*) FROM google_calendar_typed_event_tracker WHERE event_id = ?
                    """, arguments: ["ft-cancel"]) ?? -1
        }
        XCTAssertEqual(trackerCount, 0, "cancelled event must drop tracker row before transition scan")
    }

    // MARK: - 10. idempotent re-tick — no duplicate transition emission

    func testIdempotentReTickDoesNotDuplicateTransitions() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // A row that should generate _started + _ended in a single tick
        // (start_ms < now, end_ms < now, started_emitted NULL).
        try seedTrackerRow(
            db,
            eventID: "ft-bracket",
            eventType: "focusTime",
            startMs: nowMs - 10 * 60_000,
            endMs: nowMs - 60_000,
            autoDeclineMode: "declineOnlyNewConflictingInvitations",
            chatStatus: "doNotDisturb",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()
        _ = try await collector.tick()

        // After two ticks: exactly one _started + one _ended per row.
        XCTAssertEqual(
            try countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 1,
            "re-tick must not re-emit _started")
        XCTAssertEqual(
            try countTransitionEvents(db, kind: "google_calendar_focus_block_ended"), 1,
            "re-tick must not re-emit _ended")
    }

    // MARK: - 4. Blocklist eventType filter

    func testBlocklistSkipsFromGmailAndBirthdayEvents() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        let stub = StubGoogleCalendarAPIClient()
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [
                    makeEvent(id: "real-1", eventType: "default"),
                    makeEvent(id: "gmail-1", eventType: "fromGmail"),
                    makeEvent(id: "bday-1", eventType: "birthday"),
                    makeEvent(id: "real-2", eventType: "default"),
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

    // MARK: - 11. presence_state composite snapshot (Task 16)

    /// Helper — fetch the parsed `presence_state.google_calendar` state dict.
    /// Returns nil if no row exists yet.
    private func readGoogleCalendarPresenceState(
        _ db: LeafCore.Database
    ) throws -> [String: Any]? {
        try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .googleCalendar, in: rawDB)?.state
        }
    }

    func testTickWritesPresenceStateRowWithKnownCalendarCount() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try seedIntegration(db, now: now)
        // Two known calendars in rotation. Seed both BEFORE the tick so the
        // calendarList API response shape doesn't drop them via the diff
        // pruning step.
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedKnownCalendar(db, id: "team@example.com", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved-p", now: now)
        try seedEventsSyncToken(db, calendarId: "team@example.com", token: "saved-t", now: now)

        let stub = StubGoogleCalendarAPIClient()
        // Two `eventsList` (one per known calendar) + one `calendarList`
        // (piggy-back fires on tickCounter=1) — re-emit both calendars so
        // the diff doesn't prune them.
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [], nextPageToken: nil, nextSyncToken: "tick-sync-p"
            ))
        await stub.enqueueEventsList(
            makeEventsListResponse(
                items: [], nextPageToken: nil, nextSyncToken: "tick-sync-t"
            ))
        await stub.enqueueCalendarList(
            GoogleCalendarAPI.CalendarListResponse(
                items: [
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "primary", summary: nil, summaryOverride: nil,
                        primary: true, accessRole: "owner", timeZone: nil, colorId: nil
                    ),
                    GoogleCalendarAPI.CalendarListEntry(
                        id: "team@example.com", summary: nil, summaryOverride: nil,
                        primary: false, accessRole: "reader", timeZone: nil, colorId: nil
                    ),
                ],
                nextPageToken: nil, nextSyncToken: nil
            ))

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(
            try readGoogleCalendarPresenceState(db),
            "presence_state row must exist after tick")
        XCTAssertEqual(state["known_calendar_count"] as? Int, 2)
        XCTAssertEqual(state["focus_block_active"] as? Bool, false)
        XCTAssertEqual(state["ooo_active"] as? Bool, false)
        XCTAssertTrue(
            state["working_location"] is NSNull,
            "working_location must be JSON null when no active row")
        XCTAssertTrue(
            state["next_meeting_start_ms"] is NSNull,
            "next_meeting_start_ms must be JSON null when no upcoming meeting")
        // last_synced_at_ms always present, equals tick time.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(
            state["last_synced_at_ms"] as? Int64 ?? Int64(state["last_synced_at_ms"] as? Int ?? 0),
            nowMs)
    }

    func testTickWritesFocusBlockActiveTrueWhenTrackerHasActiveFocusBlock() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active focus block already _started-emitted so the transition scan
        // is a no-op — we want to isolate the presence_state hook.
        try seedTrackerRow(
            db,
            eventID: "ft-active",
            eventType: "focusTime",
            startMs: nowMs - 60_000,
            endMs: nowMs + 5 * 60_000,
            startedEmittedAtMs: nowMs - 30_000,
            autoDeclineMode: "declineOnlyNewConflictingInvitations",
            chatStatus: "doNotDisturb",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(try readGoogleCalendarPresenceState(db))
        XCTAssertEqual(state["focus_block_active"] as? Bool, true)
        XCTAssertEqual(state["ooo_active"] as? Bool, false)
        XCTAssertTrue(state["working_location"] is NSNull)
        // Moat walkback — the focus-block summary/title must never sneak
        // into the presence snapshot. Only structural counters/buckets.
        let raw = try db.readSQL { rawDB -> String in
            try String.fetchOne(
                rawDB,
                sql: "SELECT state_json FROM presence_state WHERE provider = ?",
                arguments: ["google_calendar"]
            ) ?? ""
        }
        XCTAssertFalse(
            raw.contains("summary"),
            "presence_state must not carry event summaries: \(raw)")
        XCTAssertFalse(
            raw.contains("auto_decline_mode"),
            "auto_decline_mode is per-transition; must not appear in presence: \(raw)")
    }

    func testTickWritesWorkingLocationBucketWhenActive() async throws {
        let db = try openDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedIntegration(db, now: now)
        try seedKnownCalendar(db, id: "primary", now: now)
        try seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active workingLocation row (already _started-emitted so the changed
        // transition scan is a no-op for this slice).
        try seedTrackerRow(
            db,
            eventID: "wl-active",
            eventType: "workingLocation",
            startMs: nowMs - 30 * 60_000,
            endMs: nowMs + 8 * 3600 * 1000,
            startedEmittedAtMs: nowMs - 25 * 60_000,
            workingLocationType: "homeOffice",
            now: now
        )

        let stub = StubGoogleCalendarAPIClient()
        await enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(try readGoogleCalendarPresenceState(db))
        XCTAssertEqual(state["working_location"] as? String, "homeOffice")
        XCTAssertEqual(state["focus_block_active"] as? Bool, false)
        XCTAssertEqual(state["ooo_active"] as? Bool, false)
    }
}
