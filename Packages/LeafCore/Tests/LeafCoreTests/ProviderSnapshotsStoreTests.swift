import XCTest
import GRDB
@testable import LeafCore

final class ProviderSnapshotsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-prov-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadMissingReturnsNil() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let snap = try db.readSQL { rawDB in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: "linear_subscribed_issues", in: rawDB)
        }
        XCTAssertNil(snap)
    }

    func testUpsertRoundtrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(provider: "linear", snapshotKind: "linear_subscribed_issues", snapshotJSON: "{\"ids\":[\"a\"]}", capturedAtMs: 100),
                in: rawDB
            )
        }
        let snap = try db.readSQL { rawDB in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: "linear_subscribed_issues", in: rawDB)
        }
        XCTAssertEqual(snap?.snapshotJSON, "{\"ids\":[\"a\"]}")
        XCTAssertEqual(snap?.capturedAtMs, 100)
    }

    func testUpsertOverwrites() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(provider: "linear", snapshotKind: "linear_custom_views", snapshotJSON: "v1", capturedAtMs: 1),
                in: rawDB
            )
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(provider: "linear", snapshotKind: "linear_custom_views", snapshotJSON: "v2", capturedAtMs: 2),
                in: rawDB
            )
        }
        let snap = try db.readSQL { rawDB in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: "linear_custom_views", in: rawDB)
        }
        XCTAssertEqual(snap?.snapshotJSON, "v2")
        XCTAssertEqual(snap?.capturedAtMs, 2)
    }

    func testIndependentRowsByKind() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(provider: "linear", snapshotKind: "linear_subscribed_issues", snapshotJSON: "subs", capturedAtMs: 1),
                in: rawDB
            )
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(provider: "linear", snapshotKind: "linear_custom_views", snapshotJSON: "views", capturedAtMs: 1),
                in: rawDB
            )
        }
        let subs = try db.readSQL { rawDB in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: "linear_subscribed_issues", in: rawDB)
        }
        let views = try db.readSQL { rawDB in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: "linear_custom_views", in: rawDB)
        }
        XCTAssertEqual(subs?.snapshotJSON, "subs")
        XCTAssertEqual(views?.snapshotJSON, "views")
    }
}
