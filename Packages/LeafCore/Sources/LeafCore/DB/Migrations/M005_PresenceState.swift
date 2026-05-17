import Foundation
import GRDB

/// Phase 4.7.A — `presence_state` single-row-per-provider materialized view.
/// Read by MenuBarApp self-UI и Phase 5 broadcaster (encrypted snapshot).
/// PK — `provider` ('github' | 'linear' | 'slack' | 'derived').
/// Writes идут в Track B; в Phase 4.7.A только schema готова.
extension DatabaseMigrator {
    public mutating func registerMigration005PresenceState() {
        registerMigration("005_presence_state") { db in
            try db.create(table: Schema.PresenceState.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.PresenceState.provider, .text)
                t.column(Schema.PresenceState.stateJSON, .text).notNull().defaults(to: "{}")
                t.column(Schema.PresenceState.derivedMode, .text)
                t.column(Schema.PresenceState.updatedAtMs, .integer).notNull()
            }
        }
    }
}
