import Foundation
import GRDB

/// Use-case rebuild Track C (UC-4) — persists the structured handoff context
/// card on mirrored direct messages.
///
/// `messages_mirror.context_snapshot_json` — JSON-encoded
/// `HandoffContextSnapshot` (refs/subjects/counts only, ADR-010-safe), NULL
/// for non-handoff kinds, pre-C senders and snapshots that failed tolerant
/// decode. Distinct from the existing `attachment_*` columns (single external
/// ref) — the snapshot is a structured multi-line card.
extension DatabaseMigrator {
  public mutating func registerMigration033HandoffContextSnapshot() {
    registerMigration("033_handoff_context_snapshot") { db in
      try db.execute(sql: """
        ALTER TABLE \(Schema.MessagesMirror.tableName)
          ADD COLUMN \(Schema.MessagesMirror.contextSnapshotJSON) TEXT
        """)
    }
  }
}
