// Phase 4.3 — integration test для GitHubCollector polling lifecycle.
// Mock provider в этом файле; production REST events parser tested separately
// в LeafCorePrivateTests/ProdGitHubAPIProviderTests.swift (moat, B5).

import XCTest
import os
@testable import LeafCore

final class GitHubCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "github-collector")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-github-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Mock provider

    /// Captures `since` argument для assertion в тестах. Каждый `setBatch(_:)`
    /// заменяет следующий return value.
    private actor MockGitHubAPIProvider: GitHubAPIProvider {
        private(set) var sinceCalls: [Int64?] = []
        private(set) var loginCalls: [String] = []
        private var batchToReturn: GitHubEventBatch = .empty

        func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
            sinceCalls.append(since)
            loginCalls.append(login)
            return batchToReturn
        }

        func setBatch(_ batch: GitHubEventBatch) {
            self.batchToReturn = batch
        }

        func calls() -> [Int64?] { sinceCalls }
        func logins() -> [String] { loginCalls }
    }

    // MARK: - Helpers

    /// `workspaceID = "github:<login>"` per Phase 4.3 OAuth service convention;
    /// `workspaceName` хранит raw login (без префикса) — используется как path-сегмент
    /// `/users/<login>/events`.
    private func insertFreshIntegration(
        db: Database,
        login: String = "octocat",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .github,
            workspaceID: "github:\(login)",
            workspaceName: login,
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            scope: "repo,read:user",
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }

    // MARK: - Tests

    /// Без integration row tick'и должны быть skipped (юзер не подключал GitHub).
    func testTickWithoutIntegrationSkips() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let provider = MockGitHubAPIProvider()
        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db,
            provider: provider,
            refresher: refresher,
            intervalSec: 999,
            backfillWindowDays: 7,
            logger: logger
        )

        let result = await collector.performTick()

        XCTAssertTrue(result.skipped)
        XCTAssertEqual(result.eventsProcessed, 0)
        XCTAssertNil(result.cursorAdvancedMs)

        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 0, "provider.fetchEvents не должен вызываться без integration row")
    }

    /// Со свежим integration row + 3 events от provider'а: events + offset
    /// должны попасть в БД atomically. Bootstrap path (no stored offset → since=nil).
    func testTickPersistsEventsAndCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(GitHubEventBatch(
            events: [
                GitHubEventSnapshot(
                    eventID: "e1", eventKind: "commit_pushed", repoFullName: "octocat/leaf",
                    title: "Initial commit", number: nil, sha: "abc123", branch: "main",
                    createdAtMs: cursorMs - 2000
                ),
                GitHubEventSnapshot(
                    eventID: "e2", eventKind: "pr_opened", repoFullName: "octocat/leaf",
                    title: "Add feature X", number: 42, sha: nil, branch: nil,
                    createdAtMs: cursorMs - 1000
                ),
                GitHubEventSnapshot(
                    eventID: "e3", eventKind: "issue_closed", repoFullName: "octocat/other",
                    title: "Bug Y", number: 7, sha: nil, branch: nil,
                    createdAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger
        )

        let result = await collector.performTick()

        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.eventsProcessed, 3)
        XCTAssertEqual(result.cursorAdvancedMs, cursorMs)

        // Atomic write: события + offset row должны быть в БД.
        let offset = try db.readOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: "github:octocat"
        )
        XCTAssertEqual(offset?.lastModifiedMs, cursorMs)
        XCTAssertEqual(offset?.byteOffset, 0, "byte_offset не релевантен для HTTP API")
        XCTAssertNil(offset?.inode)

        // Bootstrap: первый tick → since=nil (no stored offset).
        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 1)
        if let firstSince = calls.first {
            XCTAssertNil(firstSince, "bootstrap path → since=nil")
        } else {
            XCTFail("expected one provider call")
        }

        // Login forwarded из workspaceName (не workspaceID — тот префиксирован "github:").
        let logins = await provider.logins()
        XCTAssertEqual(logins, ["octocat"])
    }

    /// Второй tick передаёт сохранённый cursor как `since`.
    func testSecondTickPassesStoredCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(GitHubEventBatch(
            events: [GitHubEventSnapshot(
                eventID: "e1", eventKind: "commit_pushed", repoFullName: "octocat/leaf",
                title: "x", number: nil, sha: "deadbeef", branch: "main",
                createdAtMs: cursorMs
            )],
            cursorMs: cursorMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger
        )
        _ = await collector.performTick()

        // Empty batch на втором tick'е (никаких новых events).
        await provider.setBatch(.empty)
        _ = await collector.performTick()

        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0], "first tick — bootstrap")
        XCTAssertEqual(calls[1], cursorMs, "second tick — stored cursor")
    }

    /// Lifecycle smoke: start запускает loopTask, stop его cancels + awaits.
    /// Без assertion — если actor zombie'ит, тест зависнет (timeout safeguard).
    func testStartStopLifecycle() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let provider = MockGitHubAPIProvider()
        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 0.05,
            backfillWindowDays: 7,
            logger: logger
        )

        await collector.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await collector.stop()

        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 0)
    }
}
