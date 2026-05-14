// Phase Track-5 S4 — APNsTokenLocalStore singleton UPSERT coverage.

import XCTest
import GRDB
@testable import LeafCore

final class APNsTokenLocalStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-apnsstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUpsert_NewRowInserted() throws {
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: "device-1",
                apnsToken: "abc123",
                environment: Schema.APNsTokenLocal.environmentDevelopment,
                registeredAtMs: 1_000,
                in: rawDB
            )
        }

        let row = try db.readSQL {
            try APNsTokenLocalStore.read(deviceID: "device-1", in: $0)
        }
        XCTAssertEqual(row?.deviceID, "device-1")
        XCTAssertEqual(row?.apnsToken, "abc123")
        XCTAssertEqual(row?.environment, "development")
        XCTAssertEqual(row?.registeredAtMs, 1_000)
        XCTAssertNil(row?.serverSyncedAtMs)
    }

    func testUpsert_RotatesToken_ClearsServerSyncedAtMs() throws {
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: "device-1", apnsToken: "tok-a",
                environment: "development", registeredAtMs: 1_000, in: rawDB
            )
            try APNsTokenLocalStore.markServerSynced(deviceID: "device-1", atMs: 2_000, in: rawDB)
        }
        // First sync recorded.
        let synced = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "device-1", in: $0) }
        XCTAssertEqual(synced?.serverSyncedAtMs, 2_000)

        // Token rotation — server_synced should reset to NULL.
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: "device-1", apnsToken: "tok-b",
                environment: "development", registeredAtMs: 3_000, in: rawDB
            )
        }
        let rotated = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "device-1", in: $0) }
        XCTAssertEqual(rotated?.apnsToken, "tok-b")
        XCTAssertEqual(rotated?.registeredAtMs, 3_000)
        XCTAssertNil(rotated?.serverSyncedAtMs, "Token rotation should clear server_synced_at_ms")
    }

    func testRead_MissingReturnsNil() throws {
        let row = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "unknown", in: $0) }
        XCTAssertNil(row)
    }

    func testMarkServerSynced_UpdatesField() throws {
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: "device-1", apnsToken: "tok-a",
                environment: "production", registeredAtMs: 1_000, in: rawDB
            )
            try APNsTokenLocalStore.markServerSynced(deviceID: "device-1", atMs: 5_000, in: rawDB)
        }

        let row = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "device-1", in: $0) }
        XCTAssertEqual(row?.serverSyncedAtMs, 5_000)
    }

    func testMultipleDevices_RowsAreSeparate() throws {
        try db.writeSQL { rawDB in
            try APNsTokenLocalStore.upsert(
                deviceID: "device-a", apnsToken: "tok-a",
                environment: "development", registeredAtMs: 1_000, in: rawDB
            )
            try APNsTokenLocalStore.upsert(
                deviceID: "device-b", apnsToken: "tok-b",
                environment: "production", registeredAtMs: 1_000, in: rawDB
            )
        }

        let rowA = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "device-a", in: $0) }
        let rowB = try db.readSQL { try APNsTokenLocalStore.read(deviceID: "device-b", in: $0) }
        XCTAssertEqual(rowA?.apnsToken, "tok-a")
        XCTAssertEqual(rowB?.apnsToken, "tok-b")

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.APNsTokenLocal.tableName)")
            XCTAssertEqual(count, 2)
        }
    }
}
