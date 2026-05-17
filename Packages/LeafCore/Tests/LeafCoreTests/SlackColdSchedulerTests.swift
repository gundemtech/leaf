import XCTest
import os

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

final class SlackColdSchedulerTests: XCTestCase {
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-coldsched")
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-cold-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private struct AlwaysGrantedScopes: SlackScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    private func makeColdCollector() throws -> (Database, SlackColdCollector) {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = SlackColdCollector(
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

    private func makeScheduler(
        _ clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> (Database, SlackColdScheduler) {
        let (db, c) = try makeColdCollector()
        let s = SlackColdScheduler(
            database: db,
            collector: c,
            workspaceIDProvider: { nil },
            logger: logger,
            clock: clock,
            calendar: Calendar(identifier: .gregorian)
        )
        return (db, s)
    }

    func testNextLocal4amIsTomorrowIfAlreadyPast() throws {
        let (_, s) = try makeScheduler()
        // 2026-05-12 10:00:00 UTC — after 4am UTC → next 4am is 2026-05-13 04:00 UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC")!,
                year: 2026, month: 5, day: 12, hour: 10))!
        let next = s.nextLocal4am(after: now)
        XCTAssertGreaterThan(next, now)
    }

    func testNextLocal4amIsToday4amIfBefore() throws {
        // Override scheduler's calendar to UTC for deterministic test.
        let (db, c) = try makeColdCollector()
        let utc = Calendar(identifier: .gregorian)
        var utcMut = utc
        utcMut.timeZone = TimeZone(identifier: "UTC")!
        let s = SlackColdScheduler(
            database: db,
            collector: c,
            workspaceIDProvider: { nil },
            logger: logger,
            clock: { Date() },
            calendar: utcMut
        )
        let now = utcMut.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC")!,
                year: 2026, month: 5, day: 12, hour: 2))!
        let next = s.nextLocal4am(after: now)
        XCTAssertGreaterThan(next, now)
        XCTAssertLessThan(next.timeIntervalSince(now), 4 * 3600)
    }

    func testShouldCatchUpWhenOffsetMissing() throws {
        let (_, s) = try makeScheduler()
        XCTAssertTrue(s.shouldCatchUp(now: Date(), lastColdMs: nil))
    }

    func testShouldCatchUpAfter24h() throws {
        let (_, s) = try makeScheduler()
        let now = Date()
        let lastMs = Int64(now.timeIntervalSince1970 * 1000) - (25 * 3600 * 1000)
        XCTAssertTrue(s.shouldCatchUp(now: now, lastColdMs: lastMs))
    }

    func testShouldNotCatchUpWithinLast24h() throws {
        let (_, s) = try makeScheduler()
        let now = Date()
        let lastMs = Int64(now.timeIntervalSince1970 * 1000) - (1 * 3600 * 1000)
        XCTAssertFalse(s.shouldCatchUp(now: now, lastColdMs: lastMs))
    }

    func testStartStopIsIdempotent() async throws {
        let (_, s) = try makeScheduler()
        await s.start()
        await s.start()
        await s.stop()
        await s.stop()
    }

    func testStopIsPromptEvenWhenWaitingForNext4am() async throws {
        let (_, s) = try makeScheduler()
        await s.start()
        let t = Date()
        await s.stop()
        let dt = Date().timeIntervalSince(t)
        XCTAssertLessThan(dt, 1.0)
    }
}
// swiftlint:enable force_unwrapping
