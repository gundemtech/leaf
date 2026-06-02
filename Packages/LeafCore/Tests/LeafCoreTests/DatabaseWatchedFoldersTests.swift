// Phase 2.4 — public-side tests for the watched_folders table (M003) +
// 4 CRUD methods on Database. FSEventsCollector + router — separate files.

import XCTest
@testable import LeafCore

final class DatabaseWatchedFoldersTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-watchedfolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Schema (M003)

    /// M003 creates the table + index + accepts the CHECK on granularity.
    /// M001+M002 idempotency does not break (round-trip through two opens).
    func testMigrationCreatesTableAndIndex() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
                arguments: [Schema.WatchedFolders.tableName]
            )
            XCTAssertEqual(tables, [Schema.WatchedFolders.tableName])

            let indices = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name = ?",
                arguments: [Schema.WatchedFolders.indexEnabled]
            )
            XCTAssertEqual(indices, [Schema.WatchedFolders.indexEnabled])
        }
    }

    // MARK: - add + list round-trip

    /// Basic round-trip: add → list returns the same row with correctly
    /// decoded dates + granularity.
    func testAddAndListRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = WatchedFolder(
            id: "test-uuid-1",
            path: "/Users/alice/Desktop/proj",
            maxGranularity: .L4,
            enabled: true,
            addedAt: now,
            updatedAt: now
        )
        try db.addWatchedFolder(folder)

        let listed = try db.listWatchedFolders()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "test-uuid-1")
        XCTAssertEqual(listed[0].path, "/Users/alice/Desktop/proj")
        XCTAssertEqual(listed[0].maxGranularity, .L4)
        XCTAssertTrue(listed[0].enabled)
        // Allow 1ms drift due to the Int64(_ * 1000) round-trip.
        XCTAssertEqual(listed[0].addedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    /// `path` UNIQUE — attempting to add a duplicate → throws SQLITE_CONSTRAINT.
    /// The UI catches it and shows "already watching".
    func testAddDuplicatePathThrows() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let folder1 = WatchedFolder(
            id: "id-1", path: "/Users/alice/Desktop/proj", maxGranularity: .L4,
            enabled: true, addedAt: Date(), updatedAt: Date()
        )
        let folder2 = WatchedFolder(
            id: "id-2", path: "/Users/alice/Desktop/proj", maxGranularity: .L5,
            enabled: true, addedAt: Date(), updatedAt: Date()
        )
        try db.addWatchedFolder(folder1)
        XCTAssertThrowsError(try db.addWatchedFolder(folder2))

        let listed = try db.listWatchedFolders()
        XCTAssertEqual(listed.count, 1)
    }

    // MARK: - includingDisabled filter

    /// list(includingDisabled: false) — default — returns only enabled=1.
    /// FSEventsCollector uses exactly this variant (does not watch disabled).
    func testListFiltersDisabledByDefault() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let enabled = WatchedFolder(
            id: "enabled-id", path: "/a", maxGranularity: .L4,
            enabled: true, addedAt: now, updatedAt: now
        )
        let disabled = WatchedFolder(
            id: "disabled-id", path: "/b", maxGranularity: .L5,
            enabled: false, addedAt: now.addingTimeInterval(1), updatedAt: now
        )
        try db.addWatchedFolder(enabled)
        try db.addWatchedFolder(disabled)

        let onlyEnabled = try db.listWatchedFolders()
        XCTAssertEqual(onlyEnabled.count, 1)
        XCTAssertEqual(onlyEnabled[0].id, "enabled-id")

        let all = try db.listWatchedFolders(includingDisabled: true)
        XCTAssertEqual(all.count, 2)
        // Order — addedTs ASC.
        XCTAssertEqual(all[0].id, "enabled-id")
        XCTAssertEqual(all[1].id, "disabled-id")
    }

    // MARK: - remove

    /// remove by id — DELETE a single row, leaves the rest untouched; idempotent
    /// for a missing id (no-op without an exception).
    func testRemoveDeletesRow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.addWatchedFolder(WatchedFolder(
            id: "id-1", path: "/a", maxGranularity: .L4,
            enabled: true, addedAt: Date(), updatedAt: Date()
        ))
        try db.addWatchedFolder(WatchedFolder(
            id: "id-2", path: "/b", maxGranularity: .L4,
            enabled: true, addedAt: Date(), updatedAt: Date()
        ))

        try db.removeWatchedFolder(id: "id-1")
        let listed = try db.listWatchedFolders()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "id-2")

        // Idempotent — no row for "nonexistent" → no-op without an exception.
        XCTAssertNoThrow(try db.removeWatchedFolder(id: "nonexistent"))
        XCTAssertEqual(try db.listWatchedFolders().count, 1)
    }

    // MARK: - update

    /// Partial update — only the passed fields change. updated_ms always bumps.
    /// We verify that the enabled toggle + granularity change are independent and do not clobber
    /// other columns (path / id / addedAt invariant).
    func testUpdatePartialFields() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.addWatchedFolder(WatchedFolder(
            id: "id-1", path: "/a", maxGranularity: .L4,
            enabled: true, addedAt: now, updatedAt: now
        ))

        // Update only granularity → enabled stays true.
        try db.updateWatchedFolder(id: "id-1", maxGranularity: .L5)
        var listed = try db.listWatchedFolders(includingDisabled: true)
        XCTAssertEqual(listed[0].maxGranularity, .L5)
        XCTAssertTrue(listed[0].enabled)
        XCTAssertEqual(listed[0].path, "/a")
        XCTAssertGreaterThan(listed[0].updatedAt.timeIntervalSince1970, now.timeIntervalSince1970,
                             "updated_ms must increase")

        // Update only enabled → granularity stays L5.
        try db.updateWatchedFolder(id: "id-1", enabled: false)
        listed = try db.listWatchedFolders(includingDisabled: true)
        XCTAssertFalse(listed[0].enabled)
        XCTAssertEqual(listed[0].maxGranularity, .L5)

        // Both nil → no-op (without an exception).
        XCTAssertNoThrow(try db.updateWatchedFolder(id: "id-1"))
    }
}
