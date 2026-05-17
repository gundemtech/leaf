// Track-6 P4 Task 14 — GoogleCalendarCollector transition emission (focusTime,
// outOfOffice, workingLocation). Split from GoogleCalendarCollectorTests.swift
// for type_body_length / file_length.

import Foundation
import GRDB
import XCTest

@testable import LeafCore

final class GoogleCalendarCollectorTransitionTests: XCTestCase {
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

    // MARK: - 5. focusTime → started transition

    func testFocusTimeCrossingStartMsEmitsStartedTransition() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active focus block: started 1 min ago, ends in 4 min.
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        XCTAssertEqual(try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 1)
        let payloads = try Support.transitionPayloads(db, kind: "google_calendar_focus_block_started")
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
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Block already ended (end 1 min ago) and _started was emitted previously.
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        XCTAssertEqual(try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_ended"), 1)
        let payloads = try Support.transitionPayloads(db, kind: "google_calendar_focus_block_ended")
        XCTAssertTrue(payloads[0].contains("\"event_id\":\"ft-2\""))
        XCTAssertFalse(
            payloads[0].contains("auto_decline_mode"),
            "auto_decline_mode must NOT appear on _ended: \(payloads[0])")
        XCTAssertFalse(
            payloads[0].contains("chat_status"),
            "chat_status must NOT appear on _ended: \(payloads[0])")
        // _started must NOT also emit (already marked).
        XCTAssertEqual(try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 0)
    }

    // MARK: - 7. outOfOffice — autoDeclineMode on started, not on ended

    func testOOOTransitionEmitsAutoDeclineModeOnStartedNotOnEnded() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Active OOO — _started not yet emitted.
        try Support.seedTrackerRow(
            db,
            eventID: "ooo-active",
            eventType: "outOfOffice",
            startMs: nowMs - 60_000,
            endMs: nowMs + 4 * 60_000,
            autoDeclineMode: "declineAllConflictingInvitations",
            now: now
        )
        // Already-ended OOO — _started was emitted, now needs _ended.
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        // _started emitted for ooo-active.
        let started = try Support.transitionPayloads(db, kind: "google_calendar_ooo_started")
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started[0].contains("\"event_id\":\"ooo-active\""))
        XCTAssertTrue(
            started[0].contains("declineAllConflictingInvitations"),
            "auto_decline_mode must appear on OOO _started")
        XCTAssertFalse(
            started[0].contains("chat_status"),
            "chat_status is focusTime-only — must NOT appear on OOO")

        // _ended emitted for ooo-done, without auto_decline_mode.
        let ended = try Support.transitionPayloads(db, kind: "google_calendar_ooo_ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(ended[0].contains("\"event_id\":\"ooo-done\""))
        XCTAssertFalse(
            ended[0].contains("auto_decline_mode"),
            "auto_decline_mode must NOT appear on _ended")
    }

    // MARK: - 8. workingLocation single-shot _changed + idempotent on re-tick

    func testWorkingLocationCrossingStartMsEmitsChangedOnce() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()
        _ = try await collector.tick()  // idempotency re-tick

        XCTAssertEqual(
            try Support.countTransitionEvents(db, kind: "google_calendar_working_location_changed"), 1,
            "workingLocation must emit _changed exactly once across re-ticks")
        let payloads = try Support.transitionPayloads(db, kind: "google_calendar_working_location_changed")
        XCTAssertTrue(payloads[0].contains("\"working_location_type\":\"homeOffice\""))
        // Single-shot — paired _ended must never appear.
        XCTAssertEqual(try Support.countTransitionEvents(db, kind: "google_calendar_working_location_ended"), 0)
    }

    // MARK: - 9. cancelled event — tracker delete suppresses transition

    func testCancelledEventDoesNotEmitTransition() async throws {
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // Pre-seed a tracker row that the cancelled event will tombstone.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedTrackerRow(
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
            Support.makeEventsListResponse(
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
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )
        _ = try await collector.tick()

        // No transition emitted; tracker row removed.
        XCTAssertEqual(try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 0)
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
        let db = try Support.openDB(at: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try Support.seedIntegration(db, now: now)
        try Support.seedKnownCalendar(db, id: "primary", now: now)
        try Support.seedEventsSyncToken(db, calendarId: "primary", token: "saved", now: now)

        // A row that should generate _started + _ended in a single tick
        // (start_ms < now, end_ms < now, started_emitted NULL).
        try Support.seedTrackerRow(
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
        await Support.enqueueEmptyAPIResponses(stub)
        await Support.enqueueEmptyAPIResponses(stub)

        let collector = GoogleCalendarCollector(
            apiClient: stub, tokenRefresher: Support.makeRefresher(),
            database: db, clock: { now },
            pollIntervalSec: 300, calendarListEveryNTicks: 12
        )

        _ = try await collector.tick()
        _ = try await collector.tick()

        // After two ticks: exactly one _started + one _ended per row.
        XCTAssertEqual(
            try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_started"), 1,
            "re-tick must not re-emit _started")
        XCTAssertEqual(
            try Support.countTransitionEvents(db, kind: "google_calendar_focus_block_ended"), 1,
            "re-tick must not re-emit _ended")
    }
}
