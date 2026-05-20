import Foundation
import GRDB

/// M027 — CRUD over `invite_tokens` table. Static methods receive raw
/// `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`. Mirrors
/// `ShareRulesStore` / `NotificationPrefsStore` style.
///
/// The Supabase row is the source of truth; this local mirror is a cache for
/// instant Active-tokens UI. `InviteTokenService.refreshFromServer` reconciles.
public struct InviteTokenStore: Sendable {

    /// 10 active tokens per workspace per spec §7 (UI hard cap on the «Generate
    /// new» button). Service layer enforces this in a single transaction
    /// (count active → insert) — store layer does not enforce on its own.
    public static let maxActiveTokensPerWorkspace = 10

    /// INSERT a fresh token row. Throws on CHECK violation (malformed code,
    /// non-positive max_uses) or PK conflict (duplicate code — astronomically
    /// rare given 30^11 ≈ 1.77e16 random space).
    public static func insert(_ token: InviteToken, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.InviteTokens.tableName) (
                    \(Schema.InviteTokens.code),
                    \(Schema.InviteTokens.workspaceID),
                    \(Schema.InviteTokens.createdByPubkey),
                    \(Schema.InviteTokens.label),
                    \(Schema.InviteTokens.ttlSeconds),
                    \(Schema.InviteTokens.expiresAtMs),
                    \(Schema.InviteTokens.maxUses),
                    \(Schema.InviteTokens.usedCount),
                    \(Schema.InviteTokens.deletedAtMs),
                    \(Schema.InviteTokens.createdAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                token.code,
                token.workspaceID,
                token.createdByPubkeyHex,
                token.label,
                token.ttlSeconds,
                token.expiresAt.map { Self.toMs($0) },
                token.maxUses,
                token.usedCount,
                token.deletedAt.map { Self.toMs($0) },
                Self.toMs(token.createdAt)
            ]
        )
    }

    /// UPSERT — INSERT or update mutable columns (label / used_count /
    /// deleted_at_ms) on PK conflict. Used by `refreshFromServer` to reconcile.
    public static func upsert(_ token: InviteToken, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.InviteTokens.tableName) (
                    \(Schema.InviteTokens.code),
                    \(Schema.InviteTokens.workspaceID),
                    \(Schema.InviteTokens.createdByPubkey),
                    \(Schema.InviteTokens.label),
                    \(Schema.InviteTokens.ttlSeconds),
                    \(Schema.InviteTokens.expiresAtMs),
                    \(Schema.InviteTokens.maxUses),
                    \(Schema.InviteTokens.usedCount),
                    \(Schema.InviteTokens.deletedAtMs),
                    \(Schema.InviteTokens.createdAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.InviteTokens.code))
                DO UPDATE SET
                    \(Schema.InviteTokens.label)         = excluded.\(Schema.InviteTokens.label),
                    \(Schema.InviteTokens.usedCount)     = excluded.\(Schema.InviteTokens.usedCount),
                    \(Schema.InviteTokens.deletedAtMs)   = excluded.\(Schema.InviteTokens.deletedAtMs)
                """,
            arguments: [
                token.code,
                token.workspaceID,
                token.createdByPubkeyHex,
                token.label,
                token.ttlSeconds,
                token.expiresAt.map { Self.toMs($0) },
                token.maxUses,
                token.usedCount,
                token.deletedAt.map { Self.toMs($0) },
                Self.toMs(token.createdAt)
            ]
        )
    }

    public static func fetch(code: String, in db: GRDB.Database) throws -> InviteToken? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \(Schema.InviteTokens.tableName) WHERE \(Schema.InviteTokens.code) = ?",
            arguments: [code]
        ) else { return nil }
        return decode(row)
    }

    /// SELECT non-deleted + non-expired + non-exhausted rows for the workspace.
    /// `now` injected explicitly for deterministic testing.
    public static func listActive(
        workspaceID: String,
        now: Date,
        in db: GRDB.Database
    ) throws -> [InviteToken] {
        let nowMs = Self.toMs(now)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM \(Schema.InviteTokens.tableName)
                WHERE \(Schema.InviteTokens.workspaceID) = ?
                  AND \(Schema.InviteTokens.deletedAtMs) IS NULL
                  AND (\(Schema.InviteTokens.expiresAtMs) IS NULL OR \(Schema.InviteTokens.expiresAtMs) > ?)
                  AND (\(Schema.InviteTokens.maxUses) IS NULL OR \(Schema.InviteTokens.usedCount) < \(Schema.InviteTokens.maxUses))
                ORDER BY \(Schema.InviteTokens.createdAtMs) DESC
                """,
            arguments: [workspaceID, nowMs]
        )
        return rows.map(decode)
    }

    /// Lists ALL rows for the workspace including deleted/expired/exhausted —
    /// used by admin's audit view (separate from the Active tokens UI).
    public static func listAll(workspaceID: String, in db: GRDB.Database) throws -> [InviteToken] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM \(Schema.InviteTokens.tableName)
                WHERE \(Schema.InviteTokens.workspaceID) = ?
                ORDER BY \(Schema.InviteTokens.createdAtMs) DESC
                """,
            arguments: [workspaceID]
        )
        return rows.map(decode)
    }

    /// Count active (non-deleted + non-expired + non-exhausted) tokens for cap
    /// enforcement. Service layer uses this to gate `insert` at the
    /// 10-per-workspace ceiling in a single tx.
    public static func countActive(
        workspaceID: String,
        now: Date,
        in db: GRDB.Database
    ) throws -> Int {
        let nowMs = Self.toMs(now)
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM \(Schema.InviteTokens.tableName)
                WHERE \(Schema.InviteTokens.workspaceID) = ?
                  AND \(Schema.InviteTokens.deletedAtMs) IS NULL
                  AND (\(Schema.InviteTokens.expiresAtMs) IS NULL OR \(Schema.InviteTokens.expiresAtMs) > ?)
                  AND (\(Schema.InviteTokens.maxUses) IS NULL OR \(Schema.InviteTokens.usedCount) < \(Schema.InviteTokens.maxUses))
                """,
            arguments: [workspaceID, nowMs]
        ) ?? 0
    }

    /// Soft-delete by setting `deleted_at_ms`. Idempotent — re-deleting an
    /// already-deleted row simply overwrites the timestamp.
    public static func markDeleted(code: String, at: Date, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.InviteTokens.tableName)
                   SET \(Schema.InviteTokens.deletedAtMs) = ?
                 WHERE \(Schema.InviteTokens.code) = ?
                """,
            arguments: [Self.toMs(at), code]
        )
    }

    // MARK: - Row → value type

    private static func decode(_ row: Row) -> InviteToken {
        let expiresAtMs: Int64? = row[Schema.InviteTokens.expiresAtMs]
        let deletedAtMs: Int64? = row[Schema.InviteTokens.deletedAtMs]
        let createdAtMs: Int64  = row[Schema.InviteTokens.createdAtMs] ?? 0
        return InviteToken(
            code: row[Schema.InviteTokens.code],
            workspaceID: row[Schema.InviteTokens.workspaceID],
            createdByPubkeyHex: row[Schema.InviteTokens.createdByPubkey],
            label: row[Schema.InviteTokens.label],
            ttlSeconds: row[Schema.InviteTokens.ttlSeconds] ?? 0,
            expiresAt: expiresAtMs.map { fromMs($0) },
            maxUses: row[Schema.InviteTokens.maxUses],
            usedCount: row[Schema.InviteTokens.usedCount] ?? 0,
            deletedAt: deletedAtMs.map { fromMs($0) },
            createdAt: fromMs(createdAtMs)
        )
    }

    private static func toMs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
    private static func fromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

public enum InviteTokenError: Error, Sendable, Equatable {
    case maxActiveTokensReached
}
