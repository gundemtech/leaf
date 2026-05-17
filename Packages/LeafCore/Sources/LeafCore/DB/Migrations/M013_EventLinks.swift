import Foundation
import GRDB

/// Phase Track-1 D2 — cross-source link graph backing CrossSourceLinkGraph
/// derive step. Composite PK `(from_event_id, link_kind, target_ref)` dedupes
/// at insert time (`INSERT OR IGNORE`). `from_event_id` — logical FK на `events.id`,
/// SQL FOREIGN KEY не объявляется (Schema.swift §76, §86 — repo convention).
/// Reverse-lookup index `idx_event_links_target` supports D3 query path
/// "events linking to LEAF-NN".
extension DatabaseMigrator {
    public mutating func registerMigration013EventLinks() {
        registerMigration("013_event_links") { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS event_links (
                        from_event_id INTEGER NOT NULL,
                        link_kind     TEXT    NOT NULL,
                        target_kind   TEXT    NOT NULL,
                        target_ref    TEXT    NOT NULL,
                        confidence    REAL    NOT NULL,
                        created_at_ms INTEGER NOT NULL,
                        PRIMARY KEY (from_event_id, link_kind, target_ref)
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_event_links_target
                    ON event_links (target_kind, target_ref)
                    """)
        }
    }
}
