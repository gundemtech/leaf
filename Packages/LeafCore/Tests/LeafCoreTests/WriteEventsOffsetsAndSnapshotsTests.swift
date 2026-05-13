import XCTest
@testable import LeafCore

final class WriteEventsOffsetsAndSnapshotsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-write-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeOffset(_ source: String, _ ms: Int64) -> CollectorOffset {
        CollectorOffset(
            collectorID: CollectorID.linearWarmPolling, sourceID: source,
            byteOffset: 0, inode: nil, size: 0, lastModifiedMs: ms, updatedMs: ms
        )
    }

    private func makeEvent(_ ts: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: ["source": "linear", "event_kind": "linear_notification_received", "notification_id": "n1"]
        )
    }

    private func makeSnapshot(_ kind: String, _ json: String, _ ms: Int64) -> ProviderSnapshot {
        ProviderSnapshot(provider: "linear", snapshotKind: kind, snapshotJSON: json, capturedAtMs: ms)
    }

    func testHappyPathWritesAllThree() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(
            events: [makeEvent(100), makeEvent(200)],
            offsets: [makeOffset("linear:notifications:w1", 100), makeOffset("linear:cycles:w1", 200)],
            snapshots: [makeSnapshot(Schema.ProviderSnapshotKinds.linearSubscribedIssues, "{}", 200)]
        )
        XCTAssertEqual(try db.eventCount(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1))), 2)
        XCTAssertNotNil(try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:notifications:w1"))
        XCTAssertNotNil(try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:cycles:w1"))
        try db.readSQL { rawDB in
            let snap = try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues, in: rawDB)
            XCTAssertNotNil(snap)
        }
    }

    func testEmptyAllNoOps() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(events: [], offsets: [], snapshots: [])
        XCTAssertEqual(try db.eventCount(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1))), 0)
    }

    func testOnlyEventsAdvancesNothingElse() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(events: [makeEvent(50)], offsets: [], snapshots: [])
        XCTAssertEqual(try db.eventCount(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1))), 1)
        XCTAssertNil(try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:notifications:w1"))
    }

    func testOnlyOffsetsAdvancesNothingElse() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(events: [], offsets: [makeOffset("linear:notifications:w1", 999)], snapshots: [])
        let o = try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:notifications:w1")
        XCTAssertEqual(o?.lastModifiedMs, 999)
    }

    func testOnlySnapshotsWrites() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(events: [], offsets: [],
            snapshots: [makeSnapshot(Schema.ProviderSnapshotKinds.linearCustomViews, "vs", 1)])
        try db.readSQL { rawDB in
            let snap = try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearCustomViews, in: rawDB)
            XCTAssertEqual(snap?.snapshotJSON, "vs")
        }
    }

    /// Independent snapshot rows don't clobber each other within one transaction.
    func testMultipleSnapshotsIndependent() throws {
        let db = try openDB()
        try db.writeEventsOffsetsAndSnapshots(
            events: [],
            offsets: [],
            snapshots: [
                makeSnapshot(Schema.ProviderSnapshotKinds.linearSubscribedIssues, "subs", 1),
                makeSnapshot(Schema.ProviderSnapshotKinds.linearCustomViews, "views", 1),
                makeSnapshot(Schema.ProviderSnapshotKinds.linearProjectMemberships, "mems", 1)
            ]
        )
        try db.readSQL { rawDB in
            XCTAssertEqual(try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues, in: rawDB)?.snapshotJSON, "subs")
            XCTAssertEqual(try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearCustomViews, in: rawDB)?.snapshotJSON, "views")
            XCTAssertEqual(try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearProjectMemberships, in: rawDB)?.snapshotJSON, "mems")
        }
    }
}
