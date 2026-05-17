import XCTest
import os

@testable import LeafCore

final class GitHubColdSchedulerTests: XCTestCase {
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "gh-coldsched")
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gh-cold-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private struct AlwaysGrantedScopeService: GitHubScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    private func make() throws -> (Database, GitHubColdCollector, GitHubColdScheduler) {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = GitHubColdCollector(
            database: db,
            provider: StubGitHubAPIProvider(),
            refresher: GitHubTokenRefresher(database: db, clientID: "cid"),
            scopeService: AlwaysGrantedScopeService(),
            logger: logger)
        let scheduler = GitHubColdScheduler(
            database: db, collector: collector,
            loginProvider: { "octocat" }, logger: logger)
        return (db, collector, scheduler)
    }

    func testNextLocal4amBeforeMorning() throws {
        let (_, _, s) = try make()
        let cal = Calendar.current
        var components = DateComponents(year: 2026, month: 5, day: 11, hour: 3, minute: 30)
        components.timeZone = cal.timeZone
        let earlyMorning = cal.date(from: components)!
        let next = s.nextLocal4am(after: earlyMorning)
        let nextComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(nextComps.day, 11)
        XCTAssertEqual(nextComps.hour, 4)
        XCTAssertEqual(nextComps.minute, 0)
    }

    func testNextLocal4amAfterMorningRollsToTomorrow() throws {
        let (_, _, s) = try make()
        let cal = Calendar.current
        var components = DateComponents(year: 2026, month: 5, day: 11, hour: 9, minute: 0)
        components.timeZone = cal.timeZone
        let lateMorning = cal.date(from: components)!
        let next = s.nextLocal4am(after: lateMorning)
        let nextComps = cal.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(nextComps.day, 12, "Past 4am today → next 4am is tomorrow")
        XCTAssertEqual(nextComps.hour, 4)
    }

    func testNextLocal4amExactly4amRollsToTomorrow() throws {
        let (_, _, s) = try make()
        let cal = Calendar.current
        var components = DateComponents(year: 2026, month: 5, day: 11, hour: 4, minute: 0, second: 0)
        components.timeZone = cal.timeZone
        let at4am = cal.date(from: components)!
        let next = s.nextLocal4am(after: at4am)
        let nextComps = cal.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(nextComps.day, 12)
    }

    func testShouldCatchUpStaleOffset() throws {
        let (_, _, s) = try make()
        let now = Date(timeIntervalSince1970: 1_700_086_400)  // arbitrary
        let lastMs = Int64(now.timeIntervalSince1970 * 1000) - (25 * 60 * 60 * 1000)
        XCTAssertTrue(s.shouldCatchUp(now: now, lastColdMs: lastMs))
    }

    func testShouldNotCatchUpFreshOffset() throws {
        let (_, _, s) = try make()
        let now = Date(timeIntervalSince1970: 1_700_086_400)
        let lastMs = Int64(now.timeIntervalSince1970 * 1000) - (60 * 60 * 1000)
        XCTAssertFalse(s.shouldCatchUp(now: now, lastColdMs: lastMs))
    }

    func testShouldCatchUpAbsentOffset() throws {
        let (_, _, s) = try make()
        XCTAssertTrue(s.shouldCatchUp(now: Date(), lastColdMs: nil))
    }

    func testStartStopIsPrompt() async throws {
        let (_, _, s) = try make()
        await s.start()
        let t = Date()
        await s.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t), 1.0, "stop() must cancel sleep promptly")
    }
}
