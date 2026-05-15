import Foundation
import GRDB

/// Phase Track-5 S5 — CRUD over `share_rules`. Static methods receive raw
/// `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`. Mirrors
/// `MessagesMirrorStore` style.
///
/// Absent row → `ShareRuleDefaults.isEnabledByDefault(_:)` semantics. Persisted
/// row → user-overridden state (either ON or OFF).
public struct ShareRulesStore: Sendable {

    /// UPSERT on composite PK (workspace_id, source_kind). Idempotent.
    public static func upsert(
        workspaceID: String,
        source: ShareSource,
        enabled: Bool,
        updatedAtMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.ShareRules.tableName) (
                    \(Schema.ShareRules.workspaceID),
                    \(Schema.ShareRules.sourceKind),
                    \(Schema.ShareRules.enabled),
                    \(Schema.ShareRules.updatedAtMs)
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(Schema.ShareRules.workspaceID), \(Schema.ShareRules.sourceKind))
                DO UPDATE SET
                    \(Schema.ShareRules.enabled)      = excluded.\(Schema.ShareRules.enabled),
                    \(Schema.ShareRules.updatedAtMs)  = excluded.\(Schema.ShareRules.updatedAtMs)
                """,
            arguments: [workspaceID, source.rawValue, enabled ? 1 : 0, updatedAtMs]
        )
    }

    /// SELECT all rows for a workspace; returns map source → enabled. Missing
    /// sources fall back to `ShareRuleDefaults.isEnabledByDefault(_:)`. Result
    /// covers every `ShareSource.allCases` value.
    public static func readEffective(
        workspaceID: String,
        in db: GRDB.Database
    ) throws -> [ShareSource: Bool] {
        var out = ShareRuleDefaults.all
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.ShareRules.sourceKind), \(Schema.ShareRules.enabled)
                FROM \(Schema.ShareRules.tableName)
                WHERE \(Schema.ShareRules.workspaceID) = ?
                """,
            arguments: [workspaceID]
        )
        for row in rows {
            guard let rawSource = row[Schema.ShareRules.sourceKind] as String?,
                  let source = ShareSource(rawValue: rawSource),
                  let enabledRaw = row[Schema.ShareRules.enabled] as Int? else {
                continue
            }
            out[source] = enabledRaw != 0
        }
        return out
    }

    /// SELECT single (workspace_id, source) → ShareRule (only if persisted).
    public static func read(
        workspaceID: String,
        source: ShareSource,
        in db: GRDB.Database
    ) throws -> ShareRule? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.ShareRules.workspaceID),
                       \(Schema.ShareRules.sourceKind),
                       \(Schema.ShareRules.enabled),
                       \(Schema.ShareRules.updatedAtMs)
                FROM \(Schema.ShareRules.tableName)
                WHERE \(Schema.ShareRules.workspaceID) = ?
                  AND \(Schema.ShareRules.sourceKind)  = ?
                LIMIT 1
                """,
            arguments: [workspaceID, source.rawValue]
        ),
        let wsID = row[Schema.ShareRules.workspaceID] as String?,
        let srcRaw = row[Schema.ShareRules.sourceKind] as String?,
        let srcVal = ShareSource(rawValue: srcRaw),
        let enabledRaw = row[Schema.ShareRules.enabled] as Int?,
        let updatedAtMs = row[Schema.ShareRules.updatedAtMs] as Int64?
        else { return nil }

        return ShareRule(
            workspaceID: wsID,
            source: srcVal,
            enabled: enabledRaw != 0,
            updatedAtMs: updatedAtMs
        )
    }

    /// Convenience: ON/OFF resolution incorporating defaults.
    public static func isEnabled(
        workspaceID: String,
        source: ShareSource,
        in db: GRDB.Database
    ) throws -> Bool {
        let map = try readEffective(workspaceID: workspaceID, in: db)
        return map[source] ?? ShareRuleDefaults.isEnabledByDefault(source)
    }
}
