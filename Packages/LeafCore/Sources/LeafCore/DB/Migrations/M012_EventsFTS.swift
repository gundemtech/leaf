import Foundation
import GRDB

/// Phase Track-1 D2 — FTS5 keyword index over event bodies. Contentless mode
/// (`content = ''`) — the body is not duplicated in FTS internal tables (growth is
/// bounded on the `events.payload_json` side by the D1 BodyCap of 64KB).
/// Tokenizer `unicode61` Unicode-aware + `remove_diacritics 2` (ru/en mix) +
/// `tokenchars '_-'` for snake_case + kebab-case identifiers.
/// Idempotent via `IF NOT EXISTS` — reopening the DB is safe.
///
/// **Sidecar `events_fts_meta`** — contentless FTS5 does not return the values of
/// UNINDEXED columns on SELECT (even after MATCH). So, to retrieve `event_id` / `body_kind`
/// on top of a matched rowid, we keep a side table `(fts_rowid, event_id, body_kind)`,
/// written atomically together with the FTS5 INSERT in `EventsFullTextStore.indexEvent`.
/// Index `idx_events_fts_meta_event_id` for reverse lookup (D3 needs).
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

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS events_fts_meta (
                    fts_rowid INTEGER PRIMARY KEY,
                    event_id INTEGER NOT NULL,
                    body_kind TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_fts_meta_event_id
                ON events_fts_meta (event_id)
                """)
        }
    }
}
