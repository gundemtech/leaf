import Foundation
import GRDB

/// Phase Track-5 S4 — `apns_token_local` singleton-per-device APNs token row.
///
/// PK on `device_id` (IOPlatformUUID hex per Mac). One row per device. `environment`
/// CHECK enum 'development' | 'production'. `server_synced_at_ms` IS NULL → local
/// row exists but Supabase push has not yet succeeded; retried on next launch.
public extension DatabaseMigrator {
    mutating func registerMigration021APNsTokenLocal() {
        registerMigration("021_apns_token_local") { db in
            try db.create(table: Schema.APNsTokenLocal.tableName, ifNotExists: true) { t in
                t.column(Schema.APNsTokenLocal.deviceID, .text).primaryKey().notNull()
                t.column(Schema.APNsTokenLocal.apnsToken, .text).notNull()
                t.column(Schema.APNsTokenLocal.environment, .text).notNull()
                    .check { env in
                        env == Schema.APNsTokenLocal.environmentDevelopment
                            || env == Schema.APNsTokenLocal.environmentProduction
                    }
                t.column(Schema.APNsTokenLocal.registeredAtMs, .integer).notNull()
                t.column(Schema.APNsTokenLocal.lastPushedAtMs, .integer)
                t.column(Schema.APNsTokenLocal.serverSyncedAtMs, .integer)
            }
        }
    }
}
