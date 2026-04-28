import XCTest
import GRDB
@testable import LeafCore

final class MigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMigration001CreatesEventsTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.Events.tableName]
            )
            XCTAssertEqual(tables, [Schema.Events.tableName])
        }
    }

    func testMigration001CreatesBothIndexes() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.Events.tableName]
            )
            XCTAssertTrue(indexes.contains(Schema.Events.indexTs))
            XCTAssertTrue(indexes.contains(Schema.Events.indexBundleTs))
        }
    }

    func testMigration001IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        // Open + close + reopen should not error on already-applied migration.
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// M004 idempotency: повторный open после уже применённой миграции
    /// не пересоздаёт таблицу integrations и не теряет данные.
    func testMigration004IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db1 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db1.upsertIntegration(IntegrationRecord(
            provider: .linear, workspaceID: "ws", workspaceName: "Name",
            accessToken: "tok", refreshToken: nil, expiresAt: nil,
            scope: "read", connectedAt: now, updatedAt: now
        ))

        let db2 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let loaded = try db2.readIntegration(provider: .linear)
        XCTAssertEqual(loaded?.workspaceID, "ws")
    }

    func testMigrationCreatesAllExpectedColumns() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Events.tableName))"
            ).compactMap { $0["name"] as String? }

            XCTAssertTrue(columns.contains(Schema.Events.id))
            XCTAssertTrue(columns.contains(Schema.Events.ts))
            XCTAssertTrue(columns.contains(Schema.Events.signalType))
            XCTAssertTrue(columns.contains(Schema.Events.bundleID))
            XCTAssertTrue(columns.contains(Schema.Events.payloadJSON))
        }
    }

    func testPlaintextDetectionRenamesFileAndStartsFresh() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let key = EncryptionOptions(keyProvider: .data(Data(repeating: 0xDD, count: 32)))

        // Arrange: создаём plaintext DB с одним событием.
        do {
            let plain = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
            try plain.write(RawEvent(signalType: .attention, bundleID: "com.legacy"))
            try plain.checkpointWAL()
        }

        // Sanity — файл plaintext.
        let headerBefore = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBefore, Data("SQLite format 3\0".utf8))

        // Act: reopen с encryption — должен рядом появиться .bak и свежая encrypted DB.
        let encrypted = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: key)

        // Assert: .bak существует и plaintext.
        let backup = dbURL.appendingPathExtension("pre-sqlcipher.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let headerBak = try (FileHandle(forReadingFrom: backup).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBak, Data("SQLite format 3\0".utf8))

        // Новая DB encrypted: header не SQLite и пустая.
        try encrypted.checkpointWAL()
        let headerNew = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertNotEqual(headerNew, Data("SQLite format 3\0".utf8))
        let range = DateInterval(start: .distantPast, duration: 86_400_000)
        XCTAssertEqual(try encrypted.eventCount(in: range), 0)
    }
}
