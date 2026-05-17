import XCTest
import os

@testable import LeafCore

final class LinearWarmSchedulerTests: XCTestCase {
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "warmsched")
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-warm-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeWarmCollector() throws -> (Database, LinearWarmCollector) {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = LinearWarmCollector(
            database: db, provider: StubLinearGraphQLProvider(),
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            intervalSec: 900, backfillWindowDays: 7, logger: logger)
        return (db, collector)
    }

    func testStartStopIsIdempotent() async throws {
        let (_, c) = try makeWarmCollector()
        let s = LinearWarmScheduler(collector: c, intervalSec: 60, logger: logger)
        await s.start()
        await s.start()  // second start is no-op
        await s.stop()
        await s.stop()  // second stop is no-op
    }

    func testStopIsPromptEvenWithLongInterval() async throws {
        let (_, c) = try makeWarmCollector()
        let s = LinearWarmScheduler(collector: c, intervalSec: 9_999, logger: logger)
        await s.start()
        // Cancel should resolve task immediately even with a long sleep pending.
        let t = Date()
        await s.stop()
        let dt = Date().timeIntervalSince(t)
        XCTAssertLessThan(dt, 1.0, "stop() should not block on the long sleep")
    }

    func testPerformTickRunsWithoutIntegration() async throws {
        // performTick path is no-op when no integration row — must not throw.
        let (_, c) = try makeWarmCollector()
        let s = LinearWarmScheduler(collector: c, intervalSec: 900, logger: logger)
        await s.performTick()
    }
}
