// Phase 4.2 — integration test для LinearCollector polling lifecycle.
// Mock provider в этом файле; production GraphQL parser tested separately
// в LeafCorePrivateTests/ProdLinearGraphQLProviderTests.swift (moat).

import XCTest
import os
@testable import LeafCore

final class LinearCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "linear-collector")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-linear-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Mock provider

    /// Captures `since` argument для assertion в тестах. Каждый `setBatch(_:)`
    /// заменяет следующий return value.
    private actor MockLinearGraphQLProvider: LinearGraphQLProvider {
        private(set) var sinceCalls: [Int64?] = []
        private var batchToReturn: LinearIssueBatch = .empty

        func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch {
            sinceCalls.append(since)
            return batchToReturn
        }

        func setBatch(_ batch: LinearIssueBatch) {
            self.batchToReturn = batch
        }

        func calls() -> [Int64?] { sinceCalls }
    }

    // MARK: - Helpers

    private func insertFreshIntegration(
        db: Database,
        workspaceID: String = "ws-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .linear,
            workspaceID: workspaceID,
            workspaceName: "Test Workspace",
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            scope: "read",
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }

    // MARK: - Tests

    /// Без integration row tick'и должны быть skipped (юзер не подключал Linear).
    func testTickWithoutIntegrationSkips() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let provider = MockLinearGraphQLProvider()
        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db,
            provider: provider,
            refresher: refresher,
            intervalSec: 999,  // не запускаем loop — только performTick
            backfillWindowDays: 7,
            logger: logger
        )

        let result = await collector.performTick()

        XCTAssertTrue(result.skipped)
        XCTAssertEqual(result.issuesProcessed, 0)
        XCTAssertNil(result.cursorAdvancedMs)

        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 0, "provider.fetchIssues не должен вызываться без integration row")
    }

    /// Со свежим integration row + 2 issues от provider'а: events + offset
    /// должны попасть в БД atomically. Bootstrap path (no stored offset → since=nil).
    func testTickPersistsEventsAndCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-1", title: "First", status: "Done",
                    project: "Leaf", teamKey: "LEA", updatedAtMs: cursorMs - 1000
                ),
                LinearIssueSnapshot(
                    issueKey: "LEA-2", title: "Second", status: "In Progress",
                    project: "Leaf", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger
        )

        let result = await collector.performTick()

        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.issuesProcessed, 2)
        XCTAssertEqual(result.cursorAdvancedMs, cursorMs)

        // Atomic write: оба events + offset row должны быть в БД.
        let offset = try db.readOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: "linear:ws-1"
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
    }

    /// Второй tick передаёт сохранённый cursor как `since`.
    func testSecondTickPassesStoredCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(LinearIssueBatch(
            issues: [LinearIssueSnapshot(
                issueKey: "LEA-1", title: "x", status: "Done",
                project: "", teamKey: "LEA", updatedAtMs: cursorMs
            )],
            cursorMs: cursorMs
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger
        )
        _ = await collector.performTick()

        // Empty batch на втором tick'е (никаких новых issues).
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
        let provider = MockLinearGraphQLProvider()
        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 0.05,  // короткий interval — loop проворачивается раз
            backfillWindowDays: 7,
            logger: logger
        )

        await collector.start()
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms — даём loop'у проснуться 1-2 раза
        await collector.stop()

        // Provider не должен быть called (нет integration row → skip path).
        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 0)
    }
}
