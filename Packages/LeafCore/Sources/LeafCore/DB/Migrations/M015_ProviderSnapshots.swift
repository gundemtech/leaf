import Foundation
import GRDB

/// Phase Track-3 D1 — generic per-provider snapshot table for delta-mode
/// collectors. Composite PK `(provider, snapshot_kind)` caps row count by
/// provider × snapshot_kind matrix (D1 ships 4 rows, no retention needed).
/// Idempotent via `CREATE TABLE IF NOT EXISTS`.
public extension DatabaseMigrator {
    mutating func registerMigration015ProviderSnapshots() {
        registerMigration("015_provider_snapshots") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS provider_snapshots (
                    provider       TEXT    NOT NULL,
                    snapshot_kind  TEXT    NOT NULL,
                    snapshot_json  TEXT    NOT NULL,
                    captured_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (provider, snapshot_kind)
                ) WITHOUT ROWID
                """)
        }
    }
}
