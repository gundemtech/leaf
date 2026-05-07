import Foundation
import GRDB

/// Phase 5.5.A — `pending_invites` admin-side cache of issued invites.
/// PK on `token` (32-char base64url unique per relay). Lifecycle status TEXT
/// constrained to `PendingInviteStatus.rawValue` (5 cases).
///
/// Index `idx_pending_invites_status` — non-partial b-tree on `status`. Phase 5.5.C
/// reads `WHERE status='pending'` for TeamView "Pending invites" section; partial
/// index не выбран чтобы поддержать любой filter (consumed/revoked/expired) без
/// disk-cost'а separate index'а. Cardinality 5 — index size negligible.
///
/// OTP at rest: acceptable per Phase 5.5 §4.2 — sits in same SQLCipher DB as
/// teamKey (no incremental confidentiality risk).
public extension DatabaseMigrator {
    mutating func registerMigration010PendingInvites() {
        registerMigration("010_pending_invites") { db in
            try db.create(table: Schema.PendingInvites.tableName, ifNotExists: true) { t in
                t.column(Schema.PendingInvites.token, .text).primaryKey().notNull()
                t.column(Schema.PendingInvites.otp, .text).notNull()
                t.column(Schema.PendingInvites.inviteePubkeyHex, .text).notNull()
                t.column(Schema.PendingInvites.inviteeDisplayNameHint, .text)
                t.column(Schema.PendingInvites.createdAtMs, .integer).notNull()
                t.column(Schema.PendingInvites.expiresAtMs, .integer).notNull()
                t.column(Schema.PendingInvites.status, .text).notNull()
                    .defaults(to: PendingInviteStatus.pending.rawValue)
                t.column(Schema.PendingInvites.lastPolledAtMs, .integer)
            }

            try db.create(
                index: Schema.PendingInvites.indexStatus,
                on: Schema.PendingInvites.tableName,
                columns: [Schema.PendingInvites.status],
                ifNotExists: true
            )
        }
    }
}
