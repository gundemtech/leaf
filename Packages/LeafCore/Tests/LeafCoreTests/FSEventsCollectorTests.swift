// Phase 2.4 — public-side tests для FSEventsCollector lifecycle + StubFSEventsRouter.
// Не тестируем actual filesystem events (это integration smoke в Day 3) —
// только actor lifecycle: start/stop, reload diff, no-op без watched folders.

import OSLog
import XCTest

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

    /// StubFSEventsRouter всегда `.filtered("stub")`. CI-builds без moat
    /// должны компилиться + работать (collector лучшего идёт через nodes
    /// без записи событий в БД).
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

    /// start без watched folders — no-op (stream не создаётся), stop чистый.
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
        // collector сейчас в idle state — нет folders, нет stream. start() уже
        // installed notify listener + poll task; они должны cancel'ятся cleanly.
        await collector.stop()
        // Если до сюда дошли без deadlock'а — stop() корректно cancel'ит.
    }

    // MARK: - Lifecycle: with folders

    /// start с одной watched folder → stream создаётся; stop → cleanly tears down.
    /// Не проверяем events delivery (это integration smoke), только что
    /// actor лекально handle'ит paths array.
    func testStartWithOneFolder() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let watchedDir = tempDir.appendingPathComponent("watched-1", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedDir, withIntermediateDirectories: true)

        try db.addWatchedFolder(
            WatchedFolder(
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

    /// reload с no diff в paths → no-op (stream not torn down).
    /// reload с diff → stream torn down + recreated. Тест проверяет что
    /// reload не падает + не deadlock'ит при повторных вызовах.
    func testReloadIdempotentAndDiffSafe() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let folderA = tempDir.appendingPathComponent("watched-A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("watched-B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        try db.addWatchedFolder(
            WatchedFolder(
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
        try db.addWatchedFolder(
            WatchedFolder(
                id: "id-B",
                path: folderB.resolvingSymlinksInPath().path,
                maxGranularity: .L5,
                enabled: true,
                addedAt: Date().addingTimeInterval(1),
                updatedAt: Date()
            ))
        await collector.reload()

        // Disable A → reload → stream rebuilds with только B.
        try db.updateWatchedFolder(id: "id-A", enabled: false)
        await collector.reload()

        await collector.stop()
    }
}
