import Foundation
import GRDB

/// Phase Track-3 D1 — read/write API for `provider_snapshots`. Static API
/// mirrors `EventsFullTextStore` / `PresenceStateWriter` shape; callers wrap
/// in `pool.read {}` / `pool.write {}` (or use `Database.writeEventsOffsetsAndSnapshots`
/// for atomic write under collector tick).
public enum ProviderSnapshotsStore {

    public static func read(
        provider: String,
        snapshotKind: String,
        in db: GRDB.Database
    ) throws -> ProviderSnapshot? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT provider, snapshot_kind, snapshot_json, captured_at_ms FROM provider_snapshots WHERE provider = ? AND snapshot_kind = ?",
            arguments: [provider, snapshotKind]
        )
        guard let row else { return nil }
        return mapRow(row)
    }

    public static func upsert(_ snapshot: ProviderSnapshot, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO provider_snapshots (provider, snapshot_kind, snapshot_json, captured_at_ms)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(provider, snapshot_kind) DO UPDATE SET
                    snapshot_json = excluded.snapshot_json,
                    captured_at_ms = excluded.captured_at_ms
                """,
            arguments: [snapshot.provider, snapshot.snapshotKind, snapshot.snapshotJSON, snapshot.capturedAtMs]
        )
    }

    private static func mapRow(_ row: Row) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: row["provider"] as String? ?? "",
            snapshotKind: row["snapshot_kind"] as String? ?? "",
            snapshotJSON: row["snapshot_json"] as String? ?? "",
            capturedAtMs: row["captured_at_ms"] as Int64? ?? 0
        )
    }
}
