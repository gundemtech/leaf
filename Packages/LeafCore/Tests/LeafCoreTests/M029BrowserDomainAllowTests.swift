// Phase Track-6 P3 — M029 browser_domain_allow schema tests.
// Renamed from M026 (partner branch) — Track-5/S8 substrate occupies M026 on
// integration-T10. See M029_BrowserDomainAllow.swift header comment.

import XCTest
import GRDB
@testable import LeafCore

final class M029BrowserDomainAllowTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m029-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM029_TableExistsAfterMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let names = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.BrowserDomainAllow.tableName]
            )
            XCTAssertEqual(names, [Schema.BrowserDomainAllow.tableName])
        }
    }

    func testM029_InsertAndReadRow() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                INSERT INTO \(Schema.BrowserDomainAllow.tableName)
                (\(Schema.BrowserDomainAllow.domain), \(Schema.BrowserDomainAllow.granularity),
                 \(Schema.BrowserDomainAllow.addedAtMs), \(Schema.BrowserDomainAllow.notes))
                VALUES (?, ?, ?, ?)
                """,
                arguments: ["github.com", "full_url", 1700000000000, nil]
            )
        }

        try db.readSQL { rawDB in
            let row = try Row.fetchOne(
                rawDB,
                sql: "SELECT * FROM \(Schema.BrowserDomainAllow.tableName) WHERE \(Schema.BrowserDomainAllow.domain) = ?",
                arguments: ["github.com"]
            )
            XCTAssertNotNil(row)
            XCTAssertEqual(row?[Schema.BrowserDomainAllow.domain] as String?, "github.com")
            XCTAssertEqual(row?[Schema.BrowserDomainAllow.granularity] as String?, "full_url")
            XCTAssertEqual(row?[Schema.BrowserDomainAllow.addedAtMs] as Int64?, 1700000000000)
            XCTAssertNil(row?[Schema.BrowserDomainAllow.notes] as String?)
        }
    }

    func testM029_CheckConstraintRejectsInvalidGranularity() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                    INSERT INTO \(Schema.BrowserDomainAllow.tableName)
                    (\(Schema.BrowserDomainAllow.domain), \(Schema.BrowserDomainAllow.granularity),
                     \(Schema.BrowserDomainAllow.addedAtMs), \(Schema.BrowserDomainAllow.notes))
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: ["x.com", "nonsense", 1700000000001, nil]
                )
            },
            "Expected CHECK constraint violation for invalid granularity 'nonsense'"
        )
    }
}
