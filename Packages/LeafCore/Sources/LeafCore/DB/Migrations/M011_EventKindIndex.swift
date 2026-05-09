import Foundation
import GRDB

/// Phase Track-1 D1 — composite expression index on events.payload_json->>'event_kind'.
/// Supports D3 query path "events of kind X in period [a,b]" via json_extract +
/// composite (event_kind, ts) shape. SQLite expression indexes — supported since 3.9
/// (we use SQLCipher 4.x). Idempotent via IF NOT EXISTS.
public extension DatabaseMigrator {
    mutating func registerMigration011EventKindIndex() {
        registerMigration("011_event_kind_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_event_kind_ts
                ON events (json_extract(payload_json, '$.event_kind'), ts)
                """)
        }
    }
}
