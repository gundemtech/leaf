// Shared helpers for GoogleCalendarCollector*Tests files.
// Split from GoogleCalendarCollectorTests.swift for type_body_length / file_length.

import Foundation
import GRDB
import XCTest

@testable import LeafCore

struct NoopGoogleOAuthHTTP: GoogleCalendarOAuthHTTP {
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

enum GoogleCalendarCollectorTestSupport {
    static func openDB(at dbURL: URL) throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest
        )
    }

    /// Seed an IntegrationRecord for `.googleCalendar` with a TTL well in the
    /// future so the proactive refresher returns `.notDue` and never hits the
    /// noop HTTP stub.
    static func seedIntegration(_ db: LeafCore.Database, now: Date) throws {
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

    static func seedKnownCalendar(_ db: LeafCore.Database, id: String, now: Date) throws {
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

    static func seedEventsSyncToken(
        _ db: LeafCore.Database, calendarId: String, token: String, now: Date
    ) throws {
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

    static func makeRefresher() -> GoogleCalendarTokenRefresher {
        GoogleCalendarTokenRefresher(
            http: NoopGoogleOAuthHTTP(),
            clientID: "cid",
            clientSecret: "csec"
        )
    }

    static func makeEvent(
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
        // Test fixture; dict is hand-built JSON-compatible payload.
        // swiftlint:disable force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
        // swiftlint:enable force_try
    }

    static func makeEventsListResponse(
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

    static func countObservedEvents(_ db: LeafCore.Database) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(
                rawDB,
                sql: """
                    SELECT COUNT(*) FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = 'google_calendar_event_observed'
                    """) ?? 0
        }
    }

    /// Stub `eventsList` + `calendarList` responses so the tick advances past
    /// its API steps with no per-tick events, leaving only the transition-scan
    /// phase to exercise. Tracker rows are seeded directly by the test body.
    static func enqueueEmptyAPIResponses(_ stub: StubGoogleCalendarAPIClient) async {
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
    static func seedTrackerRow(
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
                GoogleCalendarTrackerStore.UpsertParams(
                    eventID: eventID,
                    calendarID: "primary",
                    iCalUID: "ical-\(eventID)",
                    eventType: eventType,
                    startMs: startMs,
                    endMs: endMs,
                    workingLocationType: workingLocationType,
                    autoDeclineMode: autoDeclineMode,
                    chatStatus: chatStatus,
                    upsertedAtMs: nowMs
                ),
                in: rawDB
            )
            if let mark = startedEmittedAtMs {
                try GoogleCalendarTrackerStore.markStartedEmitted(
                    eventID: eventID, atMs: mark, in: rawDB
                )
            }
        }
    }

    static func countTransitionEvents(_ db: LeafCore.Database, kind: String) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(
                rawDB,
                sql: """
                    SELECT COUNT(*) FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [kind]) ?? 0
        }
    }

    static func transitionPayloads(_ db: LeafCore.Database, kind: String) throws -> [String] {
        try db.readSQL { rawDB in
            try String.fetchAll(
                rawDB,
                sql: """
                    SELECT payload_json FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [kind])
        }
    }

    /// Helper — fetch the parsed `presence_state.google_calendar` state dict.
    /// Returns nil if no row exists yet.
    static func readGoogleCalendarPresenceState(
        _ db: LeafCore.Database
    ) throws -> [String: Any]? {
        try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .googleCalendar, in: rawDB)?.state
        }
    }
}
