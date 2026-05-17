import Foundation
import GRDB

/// Phase Track-1 D2 — FTS5 keyword index over event bodies. Contentless mode
/// (`content = ''`) — body не дублируется в FTS internal tables (рост контролируется
/// на стороне `events.payload_json` каплингом D1 BodyCap 64KB).
/// Tokenizer `unicode61` Unicode-aware + `remove_diacritics 2` (ru/en mix) +
/// `tokenchars '_-'` для snake_case + kebab-case identifiers.
/// Idempotent через `IF NOT EXISTS` — reopen DB безопасно.
///
/// **Sidecar `events_fts_meta`** — contentless FTS5 не возвращает значения UNINDEXED
/// колонок при SELECT (даже после MATCH). Поэтому для retrieval `event_id` / `body_kind`
/// поверх matched rowid'а держим side table `(fts_rowid, event_id, body_kind)`,
/// записывается атомарно вместе с FTS5 INSERT'ом в `EventsFullTextStore.indexEvent`.
/// Index `idx_events_fts_meta_event_id` для reverse lookup (D3 needs).
extension DatabaseMigrator {
    public mutating func registerMigration012EventsFTS() {
        registerMigration("012_events_fts") { db in
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
                        body,
                        body_kind UNINDEXED,
                        event_id UNINDEXED,
                        tokenize = "unicode61 remove_diacritics 2 tokenchars '_-'",
                        content = ''
                    )
                    """)

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS events_fts_meta (
                        fts_rowid INTEGER PRIMARY KEY,
                        event_id INTEGER NOT NULL,
                        body_kind TEXT NOT NULL
                    )
                    """)

            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_events_fts_meta_event_id
                    ON events_fts_meta (event_id)
                    """)
        }
    }
}
