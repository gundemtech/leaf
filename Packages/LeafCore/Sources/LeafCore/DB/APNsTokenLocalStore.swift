import Foundation
import GRDB

/// Phase Track-5 S4 — CRUD over `apns_token_local` singleton table. Static
/// methods receive raw `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`.
///
/// Singleton — one row per device. UPSERT pattern via `INSERT ... ON CONFLICT`
/// on PK `device_id`. `server_synced_at_ms` IS NULL → caller retries Supabase
/// sync on next launch / scenePhase=active.
public struct APNsTokenLocalStore: Sendable {

    /// UPSERT — INSERT or UPDATE on PK conflict. New apns_token replaces old.
    /// `server_synced_at_ms` cleared on UPSERT (token rotation requires fresh
    /// Supabase push).
    public static func upsert(
        deviceID: String,
        apnsToken: String,
        environment: String,
        registeredAtMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.APNsTokenLocal.tableName) (
                    \(Schema.APNsTokenLocal.deviceID),
                    \(Schema.APNsTokenLocal.apnsToken),
                    \(Schema.APNsTokenLocal.environment),
                    \(Schema.APNsTokenLocal.registeredAtMs),
                    \(Schema.APNsTokenLocal.lastPushedAtMs),
                    \(Schema.APNsTokenLocal.serverSyncedAtMs)
                ) VALUES (?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(\(Schema.APNsTokenLocal.deviceID)) DO UPDATE SET
                    \(Schema.APNsTokenLocal.apnsToken)        = excluded.\(Schema.APNsTokenLocal.apnsToken),
                    \(Schema.APNsTokenLocal.environment)      = excluded.\(Schema.APNsTokenLocal.environment),
                    \(Schema.APNsTokenLocal.registeredAtMs)   = excluded.\(Schema.APNsTokenLocal.registeredAtMs),
                    \(Schema.APNsTokenLocal.serverSyncedAtMs) = NULL
                """,
            arguments: [deviceID, apnsToken, environment, registeredAtMs]
        )
    }

    /// SELECT singleton by device_id PK.
    public static func read(
        deviceID: String,
        in db: GRDB.Database
    ) throws -> APNsTokenLocalRow? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.APNsTokenLocal.deviceID),
                       \(Schema.APNsTokenLocal.apnsToken),
                       \(Schema.APNsTokenLocal.environment),
                       \(Schema.APNsTokenLocal.registeredAtMs),
                       \(Schema.APNsTokenLocal.lastPushedAtMs),
                       \(Schema.APNsTokenLocal.serverSyncedAtMs)
                FROM \(Schema.APNsTokenLocal.tableName)
                WHERE \(Schema.APNsTokenLocal.deviceID) = ?
                LIMIT 1
                """,
            arguments: [deviceID]
        )
        return row.flatMap(Self.mapRow)
    }

    /// UPDATE server_synced_at_ms — caller invokes after successful Supabase UPSERT.
    public static func markServerSynced(
        deviceID: String,
        atMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.APNsTokenLocal.tableName)
                SET \(Schema.APNsTokenLocal.serverSyncedAtMs) = ?
                WHERE \(Schema.APNsTokenLocal.deviceID) = ?
                """,
            arguments: [atMs, deviceID]
        )
    }

    // MARK: - Private

    private static func mapRow(_ row: Row) -> APNsTokenLocalRow? {
        guard
            let deviceID = row[Schema.APNsTokenLocal.deviceID] as String?,
            let apnsToken = row[Schema.APNsTokenLocal.apnsToken] as String?,
            let environment = row[Schema.APNsTokenLocal.environment] as String?,
            let registeredAtMs = row[Schema.APNsTokenLocal.registeredAtMs] as Int64?
        else { return nil }

        return APNsTokenLocalRow(
            deviceID: deviceID,
            apnsToken: apnsToken,
            environment: environment,
            registeredAtMs: registeredAtMs,
            lastPushedAtMs: row[Schema.APNsTokenLocal.lastPushedAtMs] as Int64?,
            serverSyncedAtMs: row[Schema.APNsTokenLocal.serverSyncedAtMs] as Int64?
        )
    }
}

/// Phase Track-5 S4 — read model for `apns_token_local`.
public struct APNsTokenLocalRow: Sendable, Equatable {
    public let deviceID: String
    public let apnsToken: String
    public let environment: String
    public let registeredAtMs: Int64
    public let lastPushedAtMs: Int64?
    public let serverSyncedAtMs: Int64?

    public init(
        deviceID: String,
        apnsToken: String,
        environment: String,
        registeredAtMs: Int64,
        lastPushedAtMs: Int64? = nil,
        serverSyncedAtMs: Int64? = nil
    ) {
        self.deviceID = deviceID
        self.apnsToken = apnsToken
        self.environment = environment
        self.registeredAtMs = registeredAtMs
        self.lastPushedAtMs = lastPushedAtMs
        self.serverSyncedAtMs = serverSyncedAtMs
    }
}
