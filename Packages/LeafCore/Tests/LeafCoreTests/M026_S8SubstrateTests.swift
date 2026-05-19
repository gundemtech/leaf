// Track 5 / S8 / T1 — M026 schema check.
// Creates `notification_prefs` table (per-device toggles; T9 UI consumer).
// Extends `messages_mirror` with `pending_mark_done` flag + partial index
// (T6 retry queue consumer).

import XCTest
import GRDB
@testable import LeafCore

final class M026_S8SubstrateTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m026-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - notification_prefs

    /// M026 — `notification_prefs` table exists with required columns.
    func testM026_CreatesNotificationPrefsTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.NotificationPrefs.tableName]
            )
            XCTAssertEqual(tables, [Schema.NotificationPrefs.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.NotificationPrefs.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.NotificationPrefs.prefKind,
                    Schema.NotificationPrefs.enabled,
                    Schema.NotificationPrefs.updatedAtMs
                ])
            )

            // pref_kind = TEXT PRIMARY KEY NOT NULL
            let pkRow = try XCTUnwrap(byName[Schema.NotificationPrefs.prefKind])
            XCTAssertEqual((pkRow["type"] as String?)?.uppercased(), "TEXT")
            XCTAssertGreaterThan(pkRow["pk"] as Int? ?? 0, 0, "pref_kind must be PK")
            XCTAssertEqual(pkRow["notnull"] as Int?, 1, "pref_kind must be NOT NULL")

            // enabled = INTEGER NOT NULL DEFAULT 1
            let enabledRow = try XCTUnwrap(byName[Schema.NotificationPrefs.enabled])
            XCTAssertEqual((enabledRow["type"] as String?)?.uppercased(), "INTEGER")
            XCTAssertEqual(enabledRow["notnull"] as Int?, 1, "enabled must be NOT NULL")
            XCTAssertEqual(enabledRow["dflt_value"] as String?, "1", "enabled default must be 1")

            // updated_at_ms = INTEGER NOT NULL
            let tsRow = try XCTUnwrap(byName[Schema.NotificationPrefs.updatedAtMs])
            XCTAssertEqual((tsRow["type"] as String?)?.uppercased(), "INTEGER")
            XCTAssertEqual(tsRow["notnull"] as Int?, 1, "updated_at_ms must be NOT NULL")
        }
    }

    /// M026 — fresh table is empty (no seed rows).
    func testM026_NotificationPrefsEmptyAfterFreshMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.NotificationPrefs.tableName)")
            XCTAssertEqual(count, 0)
        }
    }

    // MARK: - messages_mirror.pending_mark_done

    /// M026 — `messages_mirror.pending_mark_done` column added (INTEGER NOT NULL DEFAULT 0).
    func testM026_AltersMessagesMirrorWithPendingMarkDone() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.MessagesMirror.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            let col = try XCTUnwrap(
                byName[Schema.MessagesMirror.pendingMarkDone],
                "expected column \(Schema.MessagesMirror.pendingMarkDone) in messages_mirror"
            )

            XCTAssertEqual((col["type"] as String?)?.uppercased(), "INTEGER")
            XCTAssertEqual(col["notnull"] as Int?, 1, "pending_mark_done must be NOT NULL")
            XCTAssertEqual(col["dflt_value"] as String?, "0", "pending_mark_done default must be 0")
            XCTAssertEqual(col["pk"] as Int?, 0, "pending_mark_done must not be part of PK")
        }
    }

    // MARK: - Partial index

    /// M026 — partial index `idx_messages_mirror_pending_mark_done` exists with
    /// a WHERE clause (qualifier ensures retry queue scan only walks pending rows).
    func testM026_PartialIndexOnPendingMarkDone() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexNames = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.MessagesMirror.tableName]
            )
            XCTAssertTrue(
                indexNames.contains(Schema.MessagesMirror.indexPendingMarkDone),
                "expected index \(Schema.MessagesMirror.indexPendingMarkDone); found \(indexNames)"
            )

            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.MessagesMirror.indexPendingMarkDone]
            )
            let indexSQL = try XCTUnwrap(sql)
            XCTAssertTrue(
                indexSQL.uppercased().contains("WHERE"),
                "Index must be partial (contain WHERE clause); found: \(indexSQL)"
            )
        }
    }

    // MARK: - Idempotency

    /// M026 — re-opening a migrated DB does not error.
    func testM026_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }
}
