// Phase 2.3 — public-side tests for byte-offset persistence (M002 + Database
// offset API). Atomic events+offset write — in a separate file below.

import XCTest
@testable import LeafCore

final class DatabaseCollectorOffsetsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-offsets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// UPSERT round-trip: insert → read → update same PK → read the updated fields.
    func testWriteAndReadOffset() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let initial = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/sessionA.jsonl",
            byteOffset: 0,
            inode: 12345,
            size: 0,
            lastModifiedMs: 1_700_000_000_000,
            updatedMs: 1_700_000_000_000
        )
        try db.writeOffset(initial)

        let read1 = try db.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/sessionA.jsonl"
        )
        XCTAssertNotNil(read1)
        XCTAssertEqual(read1?.byteOffset, 0)
        XCTAssertEqual(read1?.inode, 12345)
        XCTAssertEqual(read1?.size, 0)

        // Update — same composite PK, different mutable fields.
        let updated = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/sessionA.jsonl",
            byteOffset: 4096,
            inode: 12345,
            size: 4096,
            lastModifiedMs: 1_700_000_100_000,
            updatedMs: 1_700_000_100_000
        )
        try db.writeOffset(updated)

        let read2 = try db.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/sessionA.jsonl"
        )
        XCTAssertEqual(read2?.byteOffset, 4096, "UPSERT updated byteOffset")
        XCTAssertEqual(read2?.size, 4096, "UPSERT updated size")

        // Sanity: exactly one row (UPSERT, not a double insert).
        let listed = try db.listOffsets(collectorID: CollectorID.claudeCodeJSONL)
        XCTAssertEqual(listed.count, 1)
    }

    /// list returns only entries for the requested `collectorID`.
    /// Future collectors (FSEvents, git polling) don't get mixed up with each other.
    func testListFiltersOnCollectorID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let claudeOffset = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/cc-1.jsonl",
            byteOffset: 100, inode: 1, size: 100,
            lastModifiedMs: 1, updatedMs: 1
        )
        let otherOffset = CollectorOffset(
            collectorID: "fs_events",
            sourceID: "/tmp/watched/path",
            byteOffset: 500, inode: 2, size: 500,
            lastModifiedMs: 2, updatedMs: 2
        )
        try db.writeOffset(claudeOffset)
        try db.writeOffset(otherOffset)

        let claudeList = try db.listOffsets(collectorID: CollectorID.claudeCodeJSONL)
        XCTAssertEqual(claudeList.count, 1)
        XCTAssertEqual(claudeList.first?.sourceID, "/tmp/cc-1.jsonl")

        let fsList = try db.listOffsets(collectorID: "fs_events")
        XCTAssertEqual(fsList.count, 1)
        XCTAssertEqual(fsList.first?.sourceID, "/tmp/watched/path")

        // Unknown collector → empty.
        XCTAssertTrue(try db.listOffsets(collectorID: "nope").isEmpty)
    }

    /// M002 idempotent: open the writer twice on the same DB → the table exists once,
    /// no crash, M001 events table stays functional.
    func testMigrationIdempotent() throws {
        // First open — creates both tables.
        let db1 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db1.write(RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signalType: .attention,
            bundleID: "com.apple.Xcode",
            payload: [:]
        ))
        try db1.checkpointWAL()

        // Second open — migrations should be skipped by GRDB based on the identifier "002_collector_offsets".
        let db2 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Schema check — both tables are present.
        try db2.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN (?, ?) ORDER BY name",
                arguments: [Schema.Events.tableName, Schema.CollectorOffsets.tableName]
            )
            XCTAssertEqual(
                tables.sorted(),
                [Schema.CollectorOffsets.tableName, Schema.Events.tableName].sorted()
            )
        }

        // The existing event is intact — M002 did not wipe M001 data.
        let count = try db2.eventCount(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_699_000_000),
            end: Date(timeIntervalSince1970: 1_701_000_000)
        ))
        XCTAssertEqual(count, 1, "events from the first open were preserved")
    }
}
