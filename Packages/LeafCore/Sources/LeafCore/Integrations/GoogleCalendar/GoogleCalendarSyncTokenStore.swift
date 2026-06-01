import Foundation
import GRDB

/// Phase Track-6 P4 — thin wrapper over `provider_snapshots` (M015) for Google
/// Calendar's three sync-state surfaces.
///
/// We ride the existing `(provider, snapshot_kind)` PK rather than adding a new
/// table because each piece is a small JSON blob keyed by a stable identifier
/// (calendar id or singleton) — exactly what `provider_snapshots` exists for.
///
/// **Per-calendar isolation matters** — losing or corrupting one calendar's
/// `syncToken` forces a full re-bootstrap of THAT calendar's events stream
/// (Google returns 410 Gone otherwise). Keeping each calendar under its own
/// `sync_token:events:<calendarId>` row avoids cross-contamination, and lets
/// us delete a single row when the user unticks a calendar without disturbing
/// the others.
///
/// **Bootstrap-in-progress flag** is part of the same row (not a separate
/// table) because crash-recovery needs an atomic "did we finish the first
/// listEvents pageThrough?" check together with the token itself. A
/// half-written token without the flag would be indistinguishable from a
/// successful steady-state cursor.
public enum GoogleCalendarSyncTokenStore {

    public static let providerName = "google_calendar"

    // MARK: - Codable shapes

    public struct EventsSyncCursor: Codable, Sendable, Equatable, Hashable {
        public let token: String?
        public let lastFullSyncAtMs: Int64
        public let bootstrapInProgress: Bool

        public init(token: String?, lastFullSyncAtMs: Int64, bootstrapInProgress: Bool) {
            self.token = token
            self.lastFullSyncAtMs = lastFullSyncAtMs
            self.bootstrapInProgress = bootstrapInProgress
        }
    }

    public struct CalendarListSyncCursor: Codable, Sendable, Equatable, Hashable {
        public let token: String?
        public let lastFullSyncAtMs: Int64

        public init(token: String?, lastFullSyncAtMs: Int64) {
            self.token = token
            self.lastFullSyncAtMs = lastFullSyncAtMs
        }
    }

    public struct KnownCalendar: Codable, Sendable, Equatable, Hashable {
        public let id: String
        public let summary: String?
        public let summaryOverride: String?
        public let accessRole: String  // "owner" | "writer" | "reader"
        public let primary: Bool?
        public let colorId: String?
        public let timeZone: String?

        public init(
            id: String,
            summary: String?,
            summaryOverride: String?,
            accessRole: String,
            primary: Bool?,
            colorId: String?,
            timeZone: String?
        ) {
            self.id = id
            self.summary = summary
            self.summaryOverride = summaryOverride
            self.accessRole = accessRole
            self.primary = primary
            self.colorId = colorId
            self.timeZone = timeZone
        }
    }

    // MARK: - snapshot_kind composition

    public static func eventsSyncKind(forCalendarId calendarId: String) -> String {
        "sync_token:events:\(calendarId)"
    }

    public static let calendarListSyncKind = "sync_token:calendar_list"
    public static let knownCalendarsKind = "known_calendars"

    // MARK: - Events sync token (per-calendar)

    public static func upsertEventsSyncToken(
        calendarId: String,
        token: String?,
        lastFullSyncAtMs: Int64,
        bootstrapInProgress: Bool,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        let cursor = EventsSyncCursor(
            token: token,
            lastFullSyncAtMs: lastFullSyncAtMs,
            bootstrapInProgress: bootstrapInProgress
        )
        let json = try encodeJSON(cursor)
        try ProviderSnapshotsStore.upsert(
            ProviderSnapshot(
                provider: providerName,
                snapshotKind: eventsSyncKind(forCalendarId: calendarId),
                snapshotJSON: json,
                capturedAtMs: nowMs
            ),
            in: db
        )
    }

    public static func eventsSyncToken(
        calendarId: String,
        in db: GRDB.Database
    ) throws -> EventsSyncCursor? {
        guard
            let snap = try ProviderSnapshotsStore.read(
                provider: providerName,
                snapshotKind: eventsSyncKind(forCalendarId: calendarId),
                in: db
            )
        else { return nil }
        return try decodeJSON(EventsSyncCursor.self, from: snap.snapshotJSON)
    }

    public static func deleteEventsSyncToken(
        calendarId: String,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM provider_snapshots WHERE provider = ? AND snapshot_kind = ?",
            arguments: [providerName, eventsSyncKind(forCalendarId: calendarId)]
        )
    }

    /// Flip the bootstrap flag to `true` without disturbing any pre-existing
    /// token (idempotent — re-read current row, overwrite). Used before the
    /// first listEvents page to mark recovery state.
    public static func markBootstrapInProgress(
        calendarId: String,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        let existing = try eventsSyncToken(calendarId: calendarId, in: db)
        let cursor = EventsSyncCursor(
            token: existing?.token,
            lastFullSyncAtMs: existing?.lastFullSyncAtMs ?? 0,
            bootstrapInProgress: true
        )
        let json = try encodeJSON(cursor)
        try ProviderSnapshotsStore.upsert(
            ProviderSnapshot(
                provider: providerName,
                snapshotKind: eventsSyncKind(forCalendarId: calendarId),
                snapshotJSON: json,
                capturedAtMs: nowMs
            ),
            in: db
        )
    }

    // MARK: - Calendar-list sync token (singleton)

    public static func upsertCalendarListSyncToken(
        token: String?,
        lastFullSyncAtMs: Int64,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        let cursor = CalendarListSyncCursor(token: token, lastFullSyncAtMs: lastFullSyncAtMs)
        let json = try encodeJSON(cursor)
        try ProviderSnapshotsStore.upsert(
            ProviderSnapshot(
                provider: providerName,
                snapshotKind: calendarListSyncKind,
                snapshotJSON: json,
                capturedAtMs: nowMs
            ),
            in: db
        )
    }

    public static func calendarListSyncToken(in db: GRDB.Database) throws -> CalendarListSyncCursor? {
        guard
            let snap = try ProviderSnapshotsStore.read(
                provider: providerName,
                snapshotKind: calendarListSyncKind,
                in: db
            )
        else { return nil }
        return try decodeJSON(CalendarListSyncCursor.self, from: snap.snapshotJSON)
    }

    // MARK: - Known calendars (singleton array)

    private struct KnownCalendarsEnvelope: Codable {
        let calendars: [KnownCalendar]
    }

    public static func upsertKnownCalendars(
        _ cals: [KnownCalendar],
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        let json = try encodeJSON(KnownCalendarsEnvelope(calendars: cals))
        try ProviderSnapshotsStore.upsert(
            ProviderSnapshot(
                provider: providerName,
                snapshotKind: knownCalendarsKind,
                snapshotJSON: json,
                capturedAtMs: nowMs
            ),
            in: db
        )
    }

    public static func knownCalendars(in db: GRDB.Database) throws -> [KnownCalendar] {
        guard
            let snap = try ProviderSnapshotsStore.read(
                provider: providerName,
                snapshotKind: knownCalendarsKind,
                in: db
            )
        else { return [] }
        let env = try decodeJSON(KnownCalendarsEnvelope.self, from: snap.snapshotJSON)
        return env.calendars
    }

    // MARK: - JSON helpers (deterministic encoding for test parity)

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}
