import Foundation
import GRDB

/// Phase Track-1 D3 — detection substrate. 5 tables backing the per-event +
/// scheduled detector pipeline (decisions / open_questions / blockers /
/// where_stopped_log) plus per-detector progress cursor (detector_offsets).
///
/// Logical FKs only: `event_id` / `resolved_by_event_id` / `detected_by_event_id`
/// / `anchor_event_id` reference `events.id` без SQL FOREIGN KEY clause
/// (см. M013_EventLinks.swift §4-5 + Schema.swift §74-75, §219 — repo convention).
/// Cleanup orphans on `events` deletion — задача application layer (D3
/// retention sweep), не SQL CASCADE.
///
/// Partial unique index `idx_blockers_open` enforces "one OPEN blocker per
/// (target_kind, target_ref)" — resolved rows (resolved_at_ms IS NOT NULL)
/// исключены из uniqueness, что позволяет повторно открывать blocker после
/// resolve (плановое поведение D3 §3.1).
///
/// Pre-seeds `detector_offsets` тремя строками (decision / open_question /
/// blocker_pattern) — per-event detector cursors. Scheduled detectors
/// (linear_stuck / where_stopped) cursor не используют (run on-demand или
/// per-tick).
extension DatabaseMigrator {
    public mutating func registerMigration014DetectionTables() {
        registerMigration("014_detection_tables") { db in
            // MARK: decisions

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS decisions (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        event_id INTEGER NOT NULL UNIQUE,
                        topic_keywords_json TEXT NOT NULL,
                        reasoning_excerpt TEXT NOT NULL,
                        confidence REAL NOT NULL,
                        detected_at_ms INTEGER NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_decisions_detected_at
                        ON decisions(detected_at_ms)
                    """)

            // MARK: open_questions

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS open_questions (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        event_id INTEGER NOT NULL UNIQUE,
                        question_excerpt TEXT NOT NULL,
                        alternatives_json TEXT,
                        slack_thread_ts TEXT,
                        linear_issue_ref TEXT,
                        github_pr_ref TEXT,
                        resolved_by_event_id INTEGER,
                        opened_at_ms INTEGER NOT NULL,
                        resolved_at_ms INTEGER
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_open_questions_unresolved
                        ON open_questions(resolved_at_ms)
                        WHERE resolved_at_ms IS NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_open_questions_slack
                        ON open_questions(slack_thread_ts)
                        WHERE slack_thread_ts IS NOT NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_open_questions_linear
                        ON open_questions(linear_issue_ref)
                        WHERE linear_issue_ref IS NOT NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_open_questions_pr
                        ON open_questions(github_pr_ref)
                        WHERE github_pr_ref IS NOT NULL
                    """)

            // MARK: blockers

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS blockers (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        target_kind TEXT NOT NULL,
                        target_ref TEXT NOT NULL,
                        blocker_kind TEXT NOT NULL,
                        blocker_excerpt TEXT,
                        detected_by_event_id INTEGER,
                        started_at_ms INTEGER NOT NULL,
                        resolved_at_ms INTEGER,
                        resolved_by_event_id INTEGER
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_blockers_open
                        ON blockers(target_kind, target_ref)
                        WHERE resolved_at_ms IS NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_blockers_target
                        ON blockers(target_kind, target_ref)
                    """)

            // MARK: where_stopped_log

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS where_stopped_log (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        generated_at_ms INTEGER NOT NULL,
                        anchor_event_id INTEGER,
                        excerpt TEXT NOT NULL,
                        wip_signals_json TEXT
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_where_stopped_generated_at
                        ON where_stopped_log(generated_at_ms)
                    """)

            // MARK: detector_offsets (+ pre-seed)

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS detector_offsets (
                        detector_kind TEXT PRIMARY KEY,
                        cursor_event_id INTEGER NOT NULL DEFAULT 0,
                        last_run_at_ms INTEGER NOT NULL DEFAULT 0
                    )
                    """)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO detector_offsets (detector_kind) VALUES
                        ('decision'), ('open_question'), ('blocker_pattern')
                    """)
        }
    }
}
