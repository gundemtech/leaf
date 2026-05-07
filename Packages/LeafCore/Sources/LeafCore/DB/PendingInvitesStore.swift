import Foundation
import GRDB

/// Phase 5.5.A — CRUD over `pending_invites` table. Static methods receive raw
/// `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`. Mirrors
/// `PresenceStateWriter` style. No transaction management here.
public struct PendingInvitesStore: Sendable {

    /// INSERT new pending invite. Throws on UNIQUE PK conflict.
    public static func insert(_ row: PendingInvite, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.PendingInvites.tableName) (
                    \(Schema.PendingInvites.token),
                    \(Schema.PendingInvites.otp),
                    \(Schema.PendingInvites.inviteePubkeyHex),
                    \(Schema.PendingInvites.inviteeDisplayNameHint),
                    \(Schema.PendingInvites.createdAtMs),
                    \(Schema.PendingInvites.expiresAtMs),
                    \(Schema.PendingInvites.status),
                    \(Schema.PendingInvites.lastPolledAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                row.token,
                row.otp,
                row.inviteePubkeyHex,
                row.inviteeDisplayNameHint,
                row.createdAtMs,
                row.expiresAtMs,
                row.status.rawValue,
                row.lastPolledAtMs
            ]
        )
    }

    /// SELECT single by PK. nil when missing.
    public static func read(token: String, in db: GRDB.Database) throws -> PendingInvite? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.PendingInvites.token),
                       \(Schema.PendingInvites.otp),
                       \(Schema.PendingInvites.inviteePubkeyHex),
                       \(Schema.PendingInvites.inviteeDisplayNameHint),
                       \(Schema.PendingInvites.createdAtMs),
                       \(Schema.PendingInvites.expiresAtMs),
                       \(Schema.PendingInvites.status),
                       \(Schema.PendingInvites.lastPolledAtMs)
                FROM \(Schema.PendingInvites.tableName)
                WHERE \(Schema.PendingInvites.token) = ?
                LIMIT 1
                """,
            arguments: [token]
        )
        return row.flatMap(Self.mapRow)
    }

    /// SELECT all (optional status filter), ordered by created_at_ms DESC.
    public static func readAll(
        status: PendingInviteStatus? = nil,
        in db: GRDB.Database
    ) throws -> [PendingInvite] {
        let rows: [Row]
        if let status {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Schema.PendingInvites.token),
                           \(Schema.PendingInvites.otp),
                           \(Schema.PendingInvites.inviteePubkeyHex),
                           \(Schema.PendingInvites.inviteeDisplayNameHint),
                           \(Schema.PendingInvites.createdAtMs),
                           \(Schema.PendingInvites.expiresAtMs),
                           \(Schema.PendingInvites.status),
                           \(Schema.PendingInvites.lastPolledAtMs)
                    FROM \(Schema.PendingInvites.tableName)
                    WHERE \(Schema.PendingInvites.status) = ?
                    ORDER BY \(Schema.PendingInvites.createdAtMs) DESC
                    """,
                arguments: [status.rawValue]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Schema.PendingInvites.token),
                           \(Schema.PendingInvites.otp),
                           \(Schema.PendingInvites.inviteePubkeyHex),
                           \(Schema.PendingInvites.inviteeDisplayNameHint),
                           \(Schema.PendingInvites.createdAtMs),
                           \(Schema.PendingInvites.expiresAtMs),
                           \(Schema.PendingInvites.status),
                           \(Schema.PendingInvites.lastPolledAtMs)
                    FROM \(Schema.PendingInvites.tableName)
                    ORDER BY \(Schema.PendingInvites.createdAtMs) DESC
                    """
            )
        }
        return rows.compactMap(Self.mapRow)
    }

    /// Phase 5.5.C — SELECT all rows where `status != 'consumed'`, ordered by
    /// `created_at_ms` DESC. Used by UI list (consumed rows hidden — admin-side
    /// mental model "row пропал = colleague joined" per spec D1).
    public static func readAllExcludingConsumed(in db: GRDB.Database) throws -> [PendingInvite] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.PendingInvites.token),
                       \(Schema.PendingInvites.otp),
                       \(Schema.PendingInvites.inviteePubkeyHex),
                       \(Schema.PendingInvites.inviteeDisplayNameHint),
                       \(Schema.PendingInvites.createdAtMs),
                       \(Schema.PendingInvites.expiresAtMs),
                       \(Schema.PendingInvites.status),
                       \(Schema.PendingInvites.lastPolledAtMs)
                FROM \(Schema.PendingInvites.tableName)
                WHERE \(Schema.PendingInvites.status) != ?
                ORDER BY \(Schema.PendingInvites.createdAtMs) DESC
                """,
            arguments: [PendingInviteStatus.consumed.rawValue]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// UPDATE status. Silent no-op if token missing (idempotent — UI Refresh
    /// path may be called against just-revoked rows).
    public static func updateStatus(
        token: String,
        status: PendingInviteStatus,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.PendingInvites.tableName)
                SET \(Schema.PendingInvites.status) = ?
                WHERE \(Schema.PendingInvites.token) = ?
                """,
            arguments: [status.rawValue, token]
        )
    }

    /// UPDATE last_polled_at_ms. Silent no-op if token missing.
    public static func updateLastPolledAt(
        token: String,
        atMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.PendingInvites.tableName)
                SET \(Schema.PendingInvites.lastPolledAtMs) = ?
                WHERE \(Schema.PendingInvites.token) = ?
                """,
            arguments: [atMs, token]
        )
    }

    /// DELETE by PK. Idempotent (no-op on missing row).
    public static func delete(token: String, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.PendingInvites.tableName)
                WHERE \(Schema.PendingInvites.token) = ?
                """,
            arguments: [token]
        )
    }

    /// Phase 5.5.C — sweep `.pending` rows whose `expires_at_ms < nowMs` to `.expired`.
    /// Returns affected row count. Idempotent — second run on same nowMs returns 0.
    /// Caller wraps in `pool.write { ... }` (UPDATE requires writer pool).
    public static func sweepExpired(nowMs: Int64, in db: GRDB.Database) throws -> Int {
        try db.execute(
            sql: """
                UPDATE \(Schema.PendingInvites.tableName)
                SET \(Schema.PendingInvites.status) = ?
                WHERE \(Schema.PendingInvites.status) = ?
                  AND \(Schema.PendingInvites.expiresAtMs) < ?
                """,
            arguments: [
                PendingInviteStatus.expired.rawValue,
                PendingInviteStatus.pending.rawValue,
                nowMs
            ]
        )
        return db.changesCount
    }

    // MARK: - Private

    private static func mapRow(_ row: Row) -> PendingInvite? {
        guard
            let token = row[Schema.PendingInvites.token] as String?,
            let otp = row[Schema.PendingInvites.otp] as String?,
            let inviteePubkeyHex = row[Schema.PendingInvites.inviteePubkeyHex] as String?,
            let createdAtMs = row[Schema.PendingInvites.createdAtMs] as Int64?,
            let expiresAtMs = row[Schema.PendingInvites.expiresAtMs] as Int64?,
            let statusRaw = row[Schema.PendingInvites.status] as String?,
            let status = PendingInviteStatus(rawValue: statusRaw)
        else { return nil }

        let displayHint = row[Schema.PendingInvites.inviteeDisplayNameHint] as String?
        let lastPolledAtMs = row[Schema.PendingInvites.lastPolledAtMs] as Int64?

        return PendingInvite(
            token: token,
            otp: otp,
            inviteePubkeyHex: inviteePubkeyHex,
            inviteeDisplayNameHint: displayHint,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            status: status,
            lastPolledAtMs: lastPolledAtMs
        )
    }
}
