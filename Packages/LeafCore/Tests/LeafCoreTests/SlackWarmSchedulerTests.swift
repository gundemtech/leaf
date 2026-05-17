import XCTest
import os

@testable import LeafCore

final class SlackWarmSchedulerTests: XCTestCase {
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-warmsched")
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-warm-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private struct AlwaysGrantedScopes: SlackScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    private func makeWarmCollector() throws -> (Database, SlackWarmCollector) {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = SlackWarmCollector(
            database: db,
            provider: StubSlackAPIProvider(),
            tokenRefresher: SlackTokenRefresher(database: db, clientID: "cid"),
            scopes: AlwaysGrantedScopes(),
            workspaceIDProvider: { nil },
            userIDProvider: { nil },
            clock: { Date() },
            logger: logger
        )
        return (db, collector)
    }

    func testStartStopIsIdempotent() async throws {
        let (_, c) = try makeWarmCollector()
        let s = SlackWarmScheduler(collector: c, intervalSec: 60, logger: logger)
        await s.start()
        await s.start()  // second start is no-op
        await s.stop()
        await s.stop()  // second stop is no-op
    }

    func testStopIsPromptEvenWithLongInterval() async throws {
        let (_, c) = try makeWarmCollector()
        let s = SlackWarmScheduler(collector: c, intervalSec: 9_999, logger: logger)
        await s.start()
        let t = Date()
        await s.stop()
        let dt = Date().timeIntervalSince(t)
        XCTAssertLessThan(dt, 1.0, "stop() should not block on the long sleep")
    }

    func testPerformTickRunsWithoutIntegration() async throws {
        // performTick path is no-op when no integration row — must not throw.
        let (_, c) = try makeWarmCollector()
        let s = SlackWarmScheduler(collector: c, intervalSec: 900, logger: logger)
        await s.performTick()
    }
}
