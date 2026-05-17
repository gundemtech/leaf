// Phase 4.2 — integration test для LinearCollector polling lifecycle.
// Mock provider в этом файле; production GraphQL parser tested separately
// в LeafCorePrivateTests/ProdLinearGraphQLProviderTests.swift (moat).

import XCTest
import os

// Track-3 D1 — selective GRDB import to avoid `Database` symbol collision
// with `LeafCore.Database` in test helpers (e.g. `insertFreshIntegration(db: Database)`).
// Importing only `Row` keeps `Row.fetchOne/fetchAll` available without bringing
// in GRDB.Database as an ambiguous candidate at type-position.
import class GRDB.Row

@testable import LeafCore

final class LinearCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var logger: Logger { LinearCollectorTestSupport.logger }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-linear-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }


    private typealias Support = LinearCollectorTestSupport
    private typealias MockLinearGraphQLProvider = LinearCollectorTestSupport.MockLinearGraphQLProvider

    private func insertFreshIntegration(
        db: Database, workspaceID: String = "ws-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, workspaceID: workspaceID, expiresAt: expiresAt)
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
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-1", title: "First", status: "Done",
                        project: "Leaf", teamKey: "LEA", updatedAtMs: cursorMs - 1000
                    ),
                    LinearIssueSnapshot(
                        issueKey: "LEA-2", title: "Second", status: "In Progress",
                        project: "Leaf", teamKey: "LEA", updatedAtMs: cursorMs
                    ),
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
        // 2 issue_updated + 1 workload pulse (Phase 4.7.B — emit'ится every tick).
        XCTAssertEqual(result.issuesProcessed, 3)
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

    /// Phase 4.6.A.2 — `completionSeconds` из snapshot'а должно доезжать до events.payload.
    /// Snapshot с positive value → ключ `completion_seconds` присутствует;
    /// snapshot с nil → ключ ОТСУТСТВУЕТ (не "" — иначе SQL `IS NOT NULL` не отфильтрует);
    /// snapshot с 0 (instant complete) → ключ `"0"` (legitimate sample, не nil).
    func testTickEncodesCompletionSecondsInPayload() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-100", title: "completed", status: "Done",
                        project: "Leaf", teamKey: "LEA",
                        updatedAtMs: baseMs,
                        completionSeconds: 7200
                    ),
                    LinearIssueSnapshot(
                        issueKey: "LEA-101", title: "in flight", status: "In Progress",
                        project: "Leaf", teamKey: "LEA",
                        updatedAtMs: baseMs + 1000,
                        completionSeconds: nil
                    ),
                    LinearIssueSnapshot(
                        issueKey: "LEA-102", title: "instant", status: "Done",
                        project: "Leaf", teamKey: "LEA",
                        updatedAtMs: baseMs + 2000,
                        completionSeconds: 0
                    ),
                ],
                cursorMs: baseMs + 2000
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        let result = await collector.performTick()
        // 3 issue_updated + 1 workload pulse (Phase 4.7.B).
        XCTAssertEqual(result.issuesProcessed, 4)

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
            ))

        let completed = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-100" })
        XCTAssertEqual(completed.payload["completion_seconds"], "7200")

        let inFlight = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-101" })
        XCTAssertNil(
            inFlight.payload["completion_seconds"], "snapshot.completionSeconds=nil → key отсутствует, не \"\"")

        let instant = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-102" })
        XCTAssertEqual(
            instant.payload["completion_seconds"], "0",
            "instant completion (0s) — legitimate sample, key present с value \"0\"")
    }

    /// Второй tick передаёт сохранённый cursor как `since`.
    func testSecondTickPassesStoredCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-1", title: "x", status: "Done",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
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
        _ = await collector.performTick()

        // Empty batch на втором tick'е (никаких новых issues).
        await provider.setBatch(.empty)
        _ = await collector.performTick()

        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0], "first tick — bootstrap")
        XCTAssertEqual(calls[1], cursorMs, "second tick — stored cursor")
    }

    // MARK: - Phase 4.5 — attribution_v2 migration

    private func makeLinearActionEvent(issueKey: String, updatedAtMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "issue_updated",
                "issue_key": issueKey,
                "title": "x",
                "status": "Done",
                "project": "",
                "team_key": "LEA",
            ]
        )
    }

    private func makeGitHubControlEvent(updatedAtMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": "push",
                "repo": "test/repo",
            ]
        )
    }

    private func makeIsolatedSuiteName() -> String {
        "leaf-test-\(UUID().uuidString)"
    }

    /// First-start migration: wipe Linear events + cursor, preserve other-provider rows.
    func testMigrationDeletesLinearEventsAndOffset() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeEventsAndOffset(
            [
                makeLinearActionEvent(issueKey: "LEA-1", updatedAtMs: 1_700_000_000_000),
                makeLinearActionEvent(issueKey: "LEA-2", updatedAtMs: 1_700_000_001_000),
                makeLinearActionEvent(issueKey: "LEA-3", updatedAtMs: 1_700_000_002_000),
                makeGitHubControlEvent(updatedAtMs: 1_700_000_003_000),
            ],
            offset: CollectorOffset(
                collectorID: CollectorID.linearPolling,
                sourceID: "linear:ws-1",
                byteOffset: 0,
                inode: nil,
                size: 0,
                lastModifiedMs: 1_700_000_002_000,
                updatedMs: 1_700_000_002_000
            )
        )

        let provider = MockLinearGraphQLProvider()
        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let suiteName = makeIsolatedSuiteName()
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: suiteName
        )

        await collector.start()
        await collector.stop()

        let range = DateInterval(
            start: Date(timeIntervalSince1970: 1_500_000_000),
            end: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let events = try db.events(in: range)
        let linearEvents = events.filter { $0.payload["source"] == "linear" }
        let githubEvents = events.filter { $0.payload["source"] == "github" }
        XCTAssertEqual(linearEvents.count, 0, "Linear events должны быть wiped")
        XCTAssertEqual(githubEvents.count, 1, "Other-provider events должны сохраниться")

        let offset = try db.readOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: "linear:ws-1"
        )
        XCTAssertNil(offset, "Linear cursor должен быть reset")

        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertTrue(
            suite?.bool(forKey: LinearCollector.attributionV2MigrationFlagKey) ?? false,
            "Migration flag должен быть set после успешного wipe"
        )
    }

    /// Idempotency: при повторном start с уже set flag — миграция skipped,
    /// события вставленные между start'ами не wipe'ятся.
    func testMigrationIsIdempotent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let suiteName = makeIsolatedSuiteName()

        try db.writeEventsAndOffset(
            [makeLinearActionEvent(issueKey: "LEA-OLD", updatedAtMs: 1_700_000_000_000)],
            offset: nil
        )

        let provider = MockLinearGraphQLProvider()
        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let first = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: suiteName
        )
        await first.start()
        await first.stop()

        // After migration: insert new linear event, restart collector — flag set,
        // migration skipped, новый event survive.
        try db.writeEventsAndOffset(
            [makeLinearActionEvent(issueKey: "LEA-NEW", updatedAtMs: 1_700_000_500_000)],
            offset: nil
        )
        let second = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: suiteName
        )
        await second.start()
        await second.stop()

        let range = DateInterval(
            start: Date(timeIntervalSince1970: 1_500_000_000),
            end: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let events = try db.events(in: range)
        let linearEvents = events.filter { $0.payload["source"] == "linear" }
        XCTAssertEqual(linearEvents.count, 1, "Только LEA-NEW должен остаться (LEA-OLD wiped, second-start no-op)")
        XCTAssertEqual(linearEvents.first?.payload["issue_key"], "LEA-NEW")
    }
}
