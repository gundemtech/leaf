import Foundation
import GRDB

/// Phase Track-3 D3 — retroactive rename of pre-D3 Slack event_kinds lacking the
/// canonical `slack_*` prefix. Idempotent: each UPDATE filters by the old name,
/// so subsequent migrate() calls (and historic re-installs) find zero rows.
public enum M017NormalizeSlackEventKinds {
    /// 2 old → new mappings preserved verbatim. Source of truth for both the
    /// migration and DispatchCoverageTests.testSlackLegacyRenamedMatchesM017RenameMap.
    public static let renameMap: [(old: String, new: String)] = [
        ("message_authored_aggregate", "slack_message_authored_aggregate"),
        ("huddle_state_change",        "slack_huddle_state_change")
    ]

    public static func runRename(in db: GRDB.Database) throws {
        for (old, new) in renameMap {
            try db.execute(sql: """
                UPDATE events
                SET payload_json = json_set(payload_json, '$.event_kind', ?)
                WHERE json_extract(payload_json, '$.event_kind') = ?
                """, arguments: [new, old])
        }
    }
}

public extension DatabaseMigrator {
    mutating func registerMigration017NormalizeSlackEventKinds() {
        registerMigration("017_normalize_slack_event_kinds") { db in
            try M017NormalizeSlackEventKinds.runRename(in: db)
        }
    }
}
