// Phase Track-1 D2 — M012 FTS5 virtual table over event bodies.

import XCTest
import GRDB
@testable import LeafCore

final class M012EventsFTSTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m012-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM012_CreatesVirtualTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let names = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: ["events_fts"]
            )
            XCTAssertEqual(names, ["events_fts"])

            let sqlRow = try Row.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
                arguments: ["events_fts"]
            )
            let sqlStr = (sqlRow?["sql"] as String?) ?? ""
            XCTAssertTrue(sqlStr.contains("fts5("), "Should be FTS5 virtual table")
            XCTAssertTrue(sqlStr.contains("unicode61"), "Tokenizer should be unicode61")
            XCTAssertTrue(sqlStr.contains("remove_diacritics 2"), "remove_diacritics 2 expected")
            XCTAssertTrue(sqlStr.contains("tokenchars '_-'") || sqlStr.contains("tokenchars ''_-''"),
                          "tokenchars '_-' expected")
            XCTAssertTrue(sqlStr.contains("content=''") || sqlStr.contains("content = ''"),
                          "Contentless mode (content='') expected")
        }
    }

    func testM012_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM012_FullSequenceRunsCleanly() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let applied = try String.fetchAll(rawDB, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertTrue(applied.contains("012_events_fts"))
            // Track-5 S5: chain = 19 (S2) + M020+M021 (S4) + M022+M023+M024 (S5).
            // Track-5 S7: M025 (workspaces.deleted_at_ms + idx_workspaces_active).
            // Track-5 S8 T1: M026 (notification_prefs + ALTER messages_mirror.pending_mark_done).
            // M027 invite-redesign: invite_tokens + workspaces ADD COLUMN defaults.
            // M028 Track-6 P1 partial expression index (integration-T10).
            // M029 Track-6 P3 browser domain allow-list (integration-T10).
            // M030 Track-6 P4 GoogleCalendar tracker (Ph B trunk unification).
            // M031 AI Coworker P3 ai_escalation_audit (append-only reverse audit).
            // M032 AI Coworker P4 handoff_audit (append-only team-handoff reverse audit).
            XCTAssertEqual(applied.count, 33)
        }
    }

    func testM012_CreatesSidecarMetaTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            // Sidecar table exists.
            let names = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.EventsFTSMeta.tableName]
            )
            XCTAssertEqual(names, [Schema.EventsFTSMeta.tableName])

            // Columns: fts_rowid PK / event_id NOT NULL / body_kind NOT NULL.
            let pragmaRows = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(events_fts_meta)")
            let cols = pragmaRows.compactMap { $0["name"] as String? }
            XCTAssertEqual(Set(cols), Set(["fts_rowid", "event_id", "body_kind"]))

            let pkCols = pragmaRows
                .filter { ($0["pk"] as Int? ?? 0) > 0 }
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(pkCols, ["fts_rowid"], "fts_rowid is the sole PK")

            // Index for reverse-lookup by event_id exists.
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.EventsFTSMeta.indexEventID]
            )
            XCTAssertEqual(indexes, [Schema.EventsFTSMeta.indexEventID])
        }
    }
}
