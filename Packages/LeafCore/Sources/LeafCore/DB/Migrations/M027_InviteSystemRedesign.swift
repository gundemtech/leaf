import Foundation
import GRDB

/// M027 — Invite System Redesign (closed-mode MVP).
/// Spec: `docs/superpowers/specs/2026-05-20-invite-system-redesign-design.md` (v3).
///
/// 1. `invite_tokens` — admin's local mirror of own-workspace tokens for instant
///    Active-tokens UI. Server-side row in Supabase is source of truth; this
///    mirror is best-effort cache (admin refreshes via `InviteTokenService.refreshFromServer`).
///    Code format `LEAF-XXXX-XXXX-XXXX` enforced via CHECK constraint matching
///    the Supabase-side regex (alphabet excludes I/L/O/U/0/1 per spec §3.1).
/// 2. `workspaces` — ADD COLUMN `default_invite_ttl_seconds` (default 86400 = 24h)
///    + `default_single_use` (default 0). New tokens inherit these defaults
///    unless admin overrides at generate time.
///
/// `join_requests` lives ONLY in Supabase — admin queue is fetched on demand
/// (no local mirror; fresh-fetch on Settings → Pending requests open).
public extension DatabaseMigrator {
    mutating func registerMigration027InviteSystemRedesign() {
        registerMigration("027_invite_system_redesign") { db in
            // 1. invite_tokens table.
            try db.execute(sql: """
                CREATE TABLE \(Schema.InviteTokens.tableName) (
                    \(Schema.InviteTokens.code)            TEXT PRIMARY KEY,
                    \(Schema.InviteTokens.workspaceID)     TEXT NOT NULL REFERENCES \(Schema.Workspaces.tableName)(\(Schema.Workspaces.id)) ON DELETE CASCADE,
                    \(Schema.InviteTokens.createdByPubkey) TEXT NOT NULL,
                    \(Schema.InviteTokens.label)           TEXT,
                    \(Schema.InviteTokens.ttlSeconds)      INTEGER NOT NULL,
                    \(Schema.InviteTokens.expiresAtMs)     INTEGER,
                    \(Schema.InviteTokens.maxUses)         INTEGER,
                    \(Schema.InviteTokens.usedCount)       INTEGER NOT NULL DEFAULT 0,
                    \(Schema.InviteTokens.deletedAtMs)     INTEGER,
                    \(Schema.InviteTokens.createdAtMs)     INTEGER NOT NULL,
                    CHECK (\(Schema.InviteTokens.code) GLOB 'LEAF-[ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789]-[ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789]-[ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789][ABCDEFGHJKMNPQRSTVWXYZ23456789]'),
                    CHECK (\(Schema.InviteTokens.usedCount) >= 0),
                    CHECK (\(Schema.InviteTokens.maxUses) IS NULL OR \(Schema.InviteTokens.maxUses) > 0)
                )
                """)

            // 2. Partial index — hot path "list non-deleted tokens per workspace".
            // SQLite (like Postgres) requires deterministic predicate for partial
            // index. `deleted_at_ms IS NULL` is deterministic (column-only).
            try db.execute(sql: """
                CREATE INDEX \(Schema.InviteTokens.indexWorkspaceActive)
                ON \(Schema.InviteTokens.tableName) (\(Schema.InviteTokens.workspaceID))
                WHERE \(Schema.InviteTokens.deletedAtMs) IS NULL
                """)

            // 3. workspaces — ADD COLUMN defaults.
            try db.execute(sql: """
                ALTER TABLE \(Schema.Workspaces.tableName)
                ADD COLUMN \(Schema.Workspaces.defaultInviteTtlSeconds) INTEGER NOT NULL DEFAULT 86400
                """)
            try db.execute(sql: """
                ALTER TABLE \(Schema.Workspaces.tableName)
                ADD COLUMN \(Schema.Workspaces.defaultSingleUse) INTEGER NOT NULL DEFAULT 0
                """)
        }
    }
}
