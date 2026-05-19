import Foundation
import GRDB

/// Track 5 / S8 / T1 — CRUD over `notification_prefs` (M026). Static methods
/// receive raw `GRDB.Database` handle; caller wraps in `pool.writeSQL` /
/// `pool.readSQL`. Mirrors `ShareRulesStore` shape (normalized per-row +
/// defaults map fallback).
///
/// Absent row → `NotificationKind.defaultEnabled` semantics. Persisted row →
/// user-overridden state (either ON or OFF).
///
/// `.handoff` is locked-ON per Track 5 contract §10.2 — attempting
/// `setEnabled(.handoff, enabled: false, …)` throws `Error.cannotDisableLockedKind`.
/// Enabling a locked kind (redundant) is accepted silently for storage invariant.
public struct NotificationPrefsStore: Sendable {

    public enum Error: Swift.Error, Sendable, Equatable {
        case cannotDisableLockedKind
    }

    /// Hydrated `notification_prefs` row.
    public struct Row: Sendable, Equatable {
        public let kind: NotificationKind
        public let enabled: Bool
        public let updatedAtMs: Int64
    }

    /// UPSERT on PK `pref_kind`. Idempotent.
    ///
    /// Rejects `setEnabled(kind, enabled: false, …)` when `kind.locked` is true.
    /// Accepts `setEnabled(kind, enabled: true, …)` for locked kinds (no-op-style
    /// success — the locked invariant is always-ON).
    public static func setEnabled(
        _ kind: NotificationKind,
        enabled: Bool,
        updatedAtMs: Int64,
        in db: GRDB.Database
    ) throws {
        if kind.locked && !enabled {
            throw Error.cannotDisableLockedKind
        }
        try db.execute(
            sql: """
                INSERT INTO \(Schema.NotificationPrefs.tableName) (
                    \(Schema.NotificationPrefs.prefKind),
                    \(Schema.NotificationPrefs.enabled),
                    \(Schema.NotificationPrefs.updatedAtMs)
                ) VALUES (?, ?, ?)
                ON CONFLICT(\(Schema.NotificationPrefs.prefKind))
                DO UPDATE SET
                    \(Schema.NotificationPrefs.enabled)     = excluded.\(Schema.NotificationPrefs.enabled),
                    \(Schema.NotificationPrefs.updatedAtMs) = excluded.\(Schema.NotificationPrefs.updatedAtMs)
                """,
            arguments: [kind.rawValue, enabled ? 1 : 0, updatedAtMs]
        )
    }

    /// SELECT all rows; returns map kind → enabled. Missing kinds fall back to
    /// `NotificationKind.defaultEnabled`. Result covers every
    /// `NotificationKind.allCases` value.
    public static func readEffective(
        in db: GRDB.Database
    ) throws -> [NotificationKind: Bool] {
        // Seed defaults.
        var out: [NotificationKind: Bool] = NotificationKind.allCases.reduce(into: [:]) { acc, kind in
            acc[kind] = kind.defaultEnabled
        }
        let rows = try GRDB.Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.NotificationPrefs.prefKind), \(Schema.NotificationPrefs.enabled)
                FROM \(Schema.NotificationPrefs.tableName)
                """
        )
        for row in rows {
            guard let rawKind = row[Schema.NotificationPrefs.prefKind] as String?,
                  let kind = NotificationKind(rawValue: rawKind),
                  let enabledRaw = row[Schema.NotificationPrefs.enabled] as Int? else {
                continue
            }
            out[kind] = enabledRaw != 0
        }
        return out
    }

    /// SELECT single `pref_kind` → `Row` (only if persisted).
    public static func read(
        _ kind: NotificationKind,
        in db: GRDB.Database
    ) throws -> Row? {
        guard let row = try GRDB.Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.NotificationPrefs.prefKind),
                       \(Schema.NotificationPrefs.enabled),
                       \(Schema.NotificationPrefs.updatedAtMs)
                FROM \(Schema.NotificationPrefs.tableName)
                WHERE \(Schema.NotificationPrefs.prefKind) = ?
                LIMIT 1
                """,
            arguments: [kind.rawValue]
        ),
        let rawKind = row[Schema.NotificationPrefs.prefKind] as String?,
        let parsedKind = NotificationKind(rawValue: rawKind),
        let enabledRaw = row[Schema.NotificationPrefs.enabled] as Int?,
        let updatedAtMs = row[Schema.NotificationPrefs.updatedAtMs] as Int64?
        else { return nil }

        return Row(
            kind: parsedKind,
            enabled: enabledRaw != 0,
            updatedAtMs: updatedAtMs
        )
    }

    /// Convenience: ON/OFF resolution incorporating defaults.
    public static func isEnabled(
        _ kind: NotificationKind,
        in db: GRDB.Database
    ) throws -> Bool {
        let map = try readEffective(in: db)
        return map[kind] ?? kind.defaultEnabled
    }
}
