import Foundation
import GRDB

/// Phase Track-5 S5 — `share_rules` per-source toggle persistence. Composite PK
/// (workspace_id, source_kind). Row absent → `ShareRuleDefaults` semantics apply.
/// `source_kind` value space lives in `ShareSource.rawValue`; CHECK constraint
/// intentionally omitted — registry source of truth is Swift enum.
public extension DatabaseMigrator {
    mutating func registerMigration022ShareRules() {
        registerMigration("022_share_rules") { db in
            try db.create(table: Schema.ShareRules.tableName, ifNotExists: true) { t in
                t.column(Schema.ShareRules.workspaceID, .text).notNull()
                t.column(Schema.ShareRules.sourceKind, .text).notNull()
                t.column(Schema.ShareRules.enabled, .integer).notNull()
                t.column(Schema.ShareRules.updatedAtMs, .integer).notNull()
                t.primaryKey([
                    Schema.ShareRules.workspaceID,
                    Schema.ShareRules.sourceKind
                ])
            }

            try db.create(
                index: Schema.ShareRules.indexWorkspace,
                on: Schema.ShareRules.tableName,
                columns: [Schema.ShareRules.workspaceID],
                ifNotExists: true
            )
        }
    }
}
