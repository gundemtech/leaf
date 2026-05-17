import Foundation
import GRDB

/// Phase 5.3.D — `rotation_outbox` admin-side write-ahead journal of pending
/// key-rotation POSTs. Composite PK `(peer_pubkey_hex, new_key_id)` matches
/// relay's idempotency key (5.3.C). `posted_at_ms IS NULL` means the POST has
/// not yet succeeded; `KeyRotationService.resumePendingPosts()` retries on next
/// launch.
///
/// `blob` BLOB column stores the full encoded `RotationBlob` bytes — resume is
/// pure HTTP retry without re-deriving crypto (~270B × N peers ≈ 13 KB per event,
/// trivial). `kind` constrained to `'rotation'` или `'tombstone'`.
///
/// Partial index `rotation_outbox_unposted` — query "drain unposted" cheap.
extension DatabaseMigrator {
    public mutating func registerMigration009RotationOutbox() {
        registerMigration("009_rotation_outbox") { db in
            try db.create(table: Schema.RotationOutbox.tableName, ifNotExists: true) { t in
                t.column(Schema.RotationOutbox.peerPubkeyHex, .text).notNull()
                t.column(Schema.RotationOutbox.newKeyID, .text).notNull()
                t.column(Schema.RotationOutbox.priorKeyID, .text).notNull()
                t.column(Schema.RotationOutbox.kind, .text).notNull()
                    .check { $0 == "rotation" || $0 == "tombstone" }
                t.column(Schema.RotationOutbox.peerMemberID, .text).notNull()
                t.column(Schema.RotationOutbox.blob, .blob).notNull()
                t.column(Schema.RotationOutbox.expiresAtMs, .integer).notNull()
                t.column(Schema.RotationOutbox.createdAtMs, .integer).notNull()
                t.column(Schema.RotationOutbox.postedAtMs, .integer)
                t.primaryKey([
                    Schema.RotationOutbox.peerPubkeyHex,
                    Schema.RotationOutbox.newKeyID,
                ])
            }

            try db.create(
                index: Schema.RotationOutbox.indexUnposted,
                on: Schema.RotationOutbox.tableName,
                columns: [Schema.RotationOutbox.createdAtMs],
                condition: Column(Schema.RotationOutbox.postedAtMs) == nil
            )
        }
    }
}
