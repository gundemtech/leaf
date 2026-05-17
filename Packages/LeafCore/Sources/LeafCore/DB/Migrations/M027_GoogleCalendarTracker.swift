import Foundation
import GRDB

/// Phase Track-6 P4 — `google_calendar_typed_event_tracker` per-event row
/// tracking clock-driven `_started` / `_ended` / `_changed` transitions for
/// Google Calendar `eventType IN (focusTime, outOfOffice, workingLocation)`.
/// Spec §5.1. PK `event_id` — Google instance-level event id, unique within
/// the user's namespace. Two partial indexes narrow the tick-scan to rows that
/// still need transition emission (started_emitted_at_ms / ended_emitted_at_ms
/// null sentinels), with the third index supporting per-calendar pruning.
extension DatabaseMigrator {
    public mutating func registerMigration027GoogleCalendarTracker() {
        registerMigration("027_google_calendar_typed_event_tracker") { db in
            try db.create(table: Schema.GoogleCalendarTracker.tableName, ifNotExists: true) { t in
                t.column(Schema.GoogleCalendarTracker.eventID, .text).primaryKey().notNull()
                t.column(Schema.GoogleCalendarTracker.calendarID, .text).notNull()
                t.column(Schema.GoogleCalendarTracker.iCalUID, .text)
                t.column(Schema.GoogleCalendarTracker.eventType, .text).notNull()
                t.column(Schema.GoogleCalendarTracker.startMs, .integer).notNull()
                t.column(Schema.GoogleCalendarTracker.endMs, .integer).notNull()
                t.column(Schema.GoogleCalendarTracker.startedEmittedAtMs, .integer)
                t.column(Schema.GoogleCalendarTracker.endedEmittedAtMs, .integer)
                // workingLocationType: only populated for event_type='workingLocation' rows.
                // Stores the bucket string ("homeOffice" | "officeLocation" | "customLocation")
                // so presence-state reads can resolve current location without joining `events`.
                t.column(Schema.GoogleCalendarTracker.workingLocationType, .text)
                // Active-phase metadata for focusTime/outOfOffice rows — sourced from
                // the API Event's focusTimeProperties/outOfOfficeProperties so the
                // Task 14 transition scan can rebuild `_started` payloads without
                // re-fetching the Event. ADR-010: both columns hold public Google
                // API enum buckets (not freeform user text).
                t.column(Schema.GoogleCalendarTracker.autoDeclineMode, .text)
                t.column(Schema.GoogleCalendarTracker.chatStatus, .text)
                t.column(Schema.GoogleCalendarTracker.upsertedAtMs, .integer).notNull()
            }
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_gcal_tracker_scan_started
                      ON \(Schema.GoogleCalendarTracker.tableName)(\(Schema.GoogleCalendarTracker.startMs))
                      WHERE \(Schema.GoogleCalendarTracker.startedEmittedAtMs) IS NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_gcal_tracker_scan_ended
                      ON \(Schema.GoogleCalendarTracker.tableName)(\(Schema.GoogleCalendarTracker.endMs))
                      WHERE \(Schema.GoogleCalendarTracker.startedEmittedAtMs) IS NOT NULL
                        AND \(Schema.GoogleCalendarTracker.endedEmittedAtMs) IS NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_gcal_tracker_by_calendar
                      ON \(Schema.GoogleCalendarTracker.tableName)(\(Schema.GoogleCalendarTracker.calendarID))
                    """)
        }
    }
}
