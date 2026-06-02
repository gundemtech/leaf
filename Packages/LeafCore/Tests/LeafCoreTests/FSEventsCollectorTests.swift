// Phase 2.4 — public-side tests for FSEventsCollector lifecycle + StubFSEventsRouter.
// We don't test actual filesystem events (that's integration smoke in Day 3) —
// only the actor lifecycle: start/stop, reload diff, no-op without watched folders.

import XCTest
import OSLog
@testable import LeafCore

private let testLogger = Logger(subsystem: "tech.gundem.leaf.test", category: "fsec")

final class FSEventsCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-fsec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Stub router

    /// StubFSEventsRouter always returns `.filtered("stub")`. CI builds without moat
    /// must compile + run (the collector simply routes through nodes
    /// without writing events to the DB).
    func testStubRouterAlwaysFiltered() async {
        let stub = StubFSEventsRouter()
        let result = await stub.route(
            path: "/tmp/foo.swift",
            flags: 0,
            watchedFolders: [],
            now: Date()
        )
        switch result {
        case .filtered(let reason):
            XCTAssertEqual(reason, "stub")
        default:
            XCTFail("Expected .filtered, got \(result)")
        }
    }

    // MARK: - Lifecycle: empty

    /// start without watched folders — no-op (stream not created), stop is clean.
    func testStartWithoutFoldersIsNoOp() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = FSEventsCollector(
            database: db,
            router: StubFSEventsRouter(),
            reconfigPollSec: 60,
            latencySec: 0.5,
            darwinNotificationName: "tech.gundem.leaf.test-no-folders",
            logger: testLogger
        )

        await collector.start()
        // collector is now in idle state — no folders, no stream. start() already
        // installed the notify listener + poll task; they must cancel cleanly.
        await collector.stop()
        // If we got here without a deadlock — stop() cancelled correctly.
    }

    // MARK: - Lifecycle: with folders

    /// start with one watched folder → stream created; stop → cleanly tears down.
    /// We don't verify events delivery (that's integration smoke), only that
    /// the actor handles the paths array locally.
    func testStartWithOneFolder() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let watchedDir = tempDir.appendingPathComponent("watched-1", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedDir, withIntermediateDirectories: true)

        try db.addWatchedFolder(WatchedFolder(
            id: "test-id-1",
            path: watchedDir.resolvingSymlinksInPath().path,
            maxGranularity: .L4,
            enabled: true,
            addedAt: Date(),
            updatedAt: Date()
        ))

        let collector = FSEventsCollector(
            database: db,
            router: StubFSEventsRouter(),
            reconfigPollSec: 60,
            latencySec: 0.5,
            darwinNotificationName: "tech.gundem.leaf.test-one-folder",
            logger: testLogger
        )

        await collector.start()
        await collector.stop()
    }

    // MARK: - reload diff

    /// reload with no diff in paths → no-op (stream not torn down).
    /// reload with a diff → stream torn down + recreated. The test verifies that
    /// reload doesn't crash + doesn't deadlock on repeated calls.
    func testReloadIdempotentAndDiffSafe() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let folderA = tempDir.appendingPathComponent("watched-A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("watched-B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        try db.addWatchedFolder(WatchedFolder(
            id: "id-A",
            path: folderA.resolvingSymlinksInPath().path,
            maxGranularity: .L4,
            enabled: true,
            addedAt: Date(),
            updatedAt: Date()
        ))

        let collector = FSEventsCollector(
            database: db,
            router: StubFSEventsRouter(),
            reconfigPollSec: 60,
            latencySec: 0.5,
            darwinNotificationName: "tech.gundem.leaf.test-reload",
            logger: testLogger
        )

        await collector.start()

        // Idempotent reload — same folders → no diff.
        await collector.reload()

        // Add second folder + reload → diff, stream restarts.
        try db.addWatchedFolder(WatchedFolder(
            id: "id-B",
            path: folderB.resolvingSymlinksInPath().path,
            maxGranularity: .L5,
            enabled: true,
            addedAt: Date().addingTimeInterval(1),
            updatedAt: Date()
        ))
        await collector.reload()

        // Disable A → reload → stream rebuilds with only B.
        try db.updateWatchedFolder(id: "id-A", enabled: false)
        await collector.reload()

        await collector.stop()
    }
}
