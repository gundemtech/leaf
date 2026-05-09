import Foundation
import GRDB

/// Phase Track-1 D2 — FTS5 keyword index over event bodies. Contentless mode
/// (`content = ''`) — body не дублируется в FTS internal tables (рост контролируется
/// на стороне `events.payload_json` каплингом D1 BodyCap 64KB).
/// Tokenizer `unicode61` Unicode-aware + `remove_diacritics 2` (ru/en mix) +
/// `tokenchars '_-'` для snake_case + kebab-case identifiers.
/// Idempotent через `IF NOT EXISTS` — reopen DB безопасно.
public extension DatabaseMigrator {
    mutating func registerMigration012EventsFTS() {
        registerMigration("012_events_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
                    body,
                    body_kind UNINDEXED,
                    event_id UNINDEXED,
                    tokenize = "unicode61 remove_diacritics 2 tokenchars '_-'",
                    content = ''
                )
                """)
        }
    }
}
