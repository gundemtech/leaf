// Track-6 P4 Task 16 — presence_state composite snapshot writes from
// GoogleCalendarCollector tick. Split from GoogleCalendarCollectorTests.swift
// for type_body_length / file_length.

import Foundation
import GRDB
import XCTest

@testable import LeafCore

final class GoogleCalendarCollectorPresenceStateTests: XCTestCase {
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

    func testTickWritesPresenceStateRowWithKnownCalendarCount() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        // Two known calendars in rotation. Seed both BEFORE the tick so the
        // calendarList API response shape doesn't drop them via the diff
        // pruning step.
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedKnownCalendar(db, id: "team@example.com", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved-p", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "team@example.com", token: "saved-t", now: now)

        let stub = StubGoogleCalendarAPIClient()
        // Two `eventsList` (one per known calendar) + one `calendarList`
        // (piggy-back fires on tickCounter=1) — re-emit both calendars so
        // the diff doesn't prune them.
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
                items: [], nextPageToken: nil, nextSyncToken: "tick-sync-p"
            ))
        await stub.enqueueEventsList(
            Support.makeEventsListResponse(
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
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(
            try Support.readGoogleCalendarPresenceState(db),
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
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active focus block already _started-emitted so the transition scan
        // is a no-op — we want to isolate the presence_state hook.
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(try Support.readGoogleCalendarPresenceState(db))
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
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active workingLocation row (already _started-emitted so the changed
        // transition scan is a no-op for this slice).
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        let state = try XCTUnwrap(try Support.readGoogleCalendarPresenceState(db))
        XCTAssertEqual(state["working_location"] as? String, "homeOffice")
        XCTAssertEqual(state["focus_block_active"] as? Bool, false)
        XCTAssertEqual(state["ooo_active"] as? Bool, false)
    }
}
