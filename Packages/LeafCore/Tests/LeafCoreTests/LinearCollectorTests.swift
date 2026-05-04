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
        await provider.setBatch(LinearIssueBatch(
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
                )
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

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
        ))

        let completed = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-100" })
        XCTAssertEqual(completed.payload["completion_seconds"], "7200")

        let inFlight = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-101" })
        XCTAssertNil(inFlight.payload["completion_seconds"], "snapshot.completionSeconds=nil → key отсутствует, не \"\"")

        let instant = try XCTUnwrap(stored.first { $0.payload["issue_key"] == "LEA-102" })
        XCTAssertEqual(instant.payload["completion_seconds"], "0", "instant completion (0s) — legitimate sample, key present с value \"0\"")
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
                "team_key": "LEA"
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
                "repo": "test/repo"
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
                makeGitHubControlEvent(updatedAtMs: 1_700_000_003_000)
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

    // MARK: - Phase 4.7.A — linear_comment_authored

    /// Issue с count > 0 → emit linear_comment_authored event рядом с issue_updated.
    func testTickEmitsCommentEventWhenCountPositive() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        // Использую timestamp близкий к now — comment event пишется
        // с periodEndMs = now (а не cursorMs), а issue_updated с cursorMs.
        // Range query должен покрыть оба.
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-1", title: "Topic", status: "In Progress",
                    project: "Leaf", teamKey: "LEA", updatedAtMs: cursorMs,
                    completionSeconds: nil, commentCountInWindow: 4
                )
            ],
            cursorMs: cursorMs
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        let result = await collector.performTick()
        XCTAssertEqual(result.commentEventsEmitted, 1)

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let issueEvent = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "issue_updated" })
        XCTAssertEqual(issueEvent.payload["issue_key"], "LEA-1")

        let comment = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_comment_authored" })
        XCTAssertEqual(comment.payload["issue_key"], "LEA-1")
        XCTAssertEqual(comment.payload["count_in_window"], "4")
        XCTAssertEqual(comment.payload["team_key"], "LEA")
    }

    /// Issue с count=0 → no comment event.
    func testTickDoesNotEmitCommentEventWhenCountZero() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = 1_700_000_000_000
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-1", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs,
                    commentCountInWindow: 0
                )
            ],
            cursorMs: cursorMs
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        let result = await collector.performTick()
        XCTAssertEqual(result.commentEventsEmitted, 0)

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        XCTAssertNil(stored.first { $0.payload["event_kind"] == "linear_comment_authored" })
    }

    // MARK: - Phase 4.7.B — linear_assigned_workload_pulse

    /// Batch с populated workload → events array contains pulse event с
    /// payload, отражающим snapshot (started_count + top_priority + last_touched).
    func testTick_EmitsLinearWorkloadPulseEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let lastTouchedTs: Int64 = cursorMs - 1_000
        await provider.setBatch(LinearIssueBatch(
            issues: [],
            cursorMs: nil,
            transitions: [],
            workload: LinearAssignedWorkloadSnapshot(
                startedCount: 3,
                topPriority: 1,  // urgent
                lastTouchedIdentifier: "LEA-201",
                lastTouchedTs: lastTouchedTs
            )
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let pulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "linear_assigned_workload_pulse" },
            "expected one pulse event with populated workload"
        )
        XCTAssertEqual(pulse.payload["source"], "linear")
        XCTAssertEqual(pulse.payload["started_count"], "3")
        XCTAssertEqual(pulse.payload["top_priority"], "urgent")
        XCTAssertEqual(pulse.payload["last_touched_identifier"], "LEA-201")
        XCTAssertEqual(pulse.payload["last_touched_ts_ms"], String(lastTouchedTs))
        XCTAssertEqual(pulse.signalType, .context, "workload pulse — state pulse, signal_type=.context")
        // ADR-010 regression: pulse не должен нести title (snapshot его не несёт,
        // но defensive — payload не должен contain'ить любые non-whitelisted keys).
        XCTAssertNil(pulse.payload["title"])
    }

    /// Empty workload (startedCount=0) → pulse всё равно emit'ится с
    /// started_count="0" + top_priority="none" + omitted last_touched_*.
    /// Substrate consistency: downstream aggregator опирается на наличие sample.
    func testTick_LinearWorkloadPulseAlwaysEmitted() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        // Empty batch с empty workload — bootstrap path with nothing in flight.
        await provider.setBatch(.empty)

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let pulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "linear_assigned_workload_pulse" },
            "pulse должен emit'иться даже на empty workload"
        )
        XCTAssertEqual(pulse.payload["started_count"], "0")
        XCTAssertEqual(pulse.payload["top_priority"], "none",
                       "empty workload → top_priority=\"none\" (всегда present, не omitted)")
        XCTAssertNil(pulse.payload["last_touched_identifier"],
                     "nil identifier → key omitted")
        XCTAssertNil(pulse.payload["last_touched_ts_ms"],
                     "nil ts → key omitted")
    }

    // MARK: - Phase 4.7.B (B-7) — linear_cycle_progress

    /// Helper: build `LinearTeamCycleSnapshot` с разумными defaults.
    private func makeTeamCycle(
        teamID: String = "team-A",
        teamName: String = "Engineering",
        cycleID: String = "cycle-1",
        cycleName: String = "Sprint 42",
        startsAtMs: Int64 = 1_777_180_800_000,  // 2026-04-26 ~ начало
        endsAtMs: Int64 = 1_780_000_000_000,    // в будущем
        completedPct: Double = 60.0,
        daysRemaining: Int = 5,
        scopeCount: Int = 15
    ) -> LinearTeamCycleSnapshot {
        LinearTeamCycleSnapshot(
            teamID: teamID,
            teamName: teamName,
            cycleID: cycleID,
            cycleName: cycleName,
            startsAtMs: startsAtMs,
            endsAtMs: endsAtMs,
            completedPct: completedPct,
            daysRemaining: daysRemaining,
            scopeCount: scopeCount
        )
    }

    /// Plan-required: 2 teams с cycles → 2 events emitted (один per team).
    func testTick_EmitsCycleProgressPerTeam() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let teamA = makeTeamCycle(
            teamID: "team-A", teamName: "Engineering",
            cycleID: "cycle-1", cycleName: "Sprint 42",
            completedPct: 80.0, daysRemaining: 3, scopeCount: 15
        )
        let teamB = makeTeamCycle(
            teamID: "team-B", teamName: "Design",
            cycleID: "cycle-2", cycleName: "Iteration 7",
            completedPct: 50.0, daysRemaining: 7, scopeCount: 8
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [],
            cursorMs: nil,
            transitions: [],
            workload: .empty,
            cycles: LinearCycleSnapshot(teams: [teamA, teamB], observedAtMs: nowMs)
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        let result = await collector.performTick()
        XCTAssertEqual(result.cycleEventsEmitted, 2, "2 teams с cycles → 2 events")

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let cycleEvents = stored.filter { $0.payload["event_kind"] == "linear_cycle_progress" }
        XCTAssertEqual(cycleEvents.count, 2)
        let teamIDs = Set(cycleEvents.compactMap { $0.payload["team_id"] })
        XCTAssertEqual(teamIDs, ["team-A", "team-B"])

        let eventA = try XCTUnwrap(cycleEvents.first { $0.payload["team_id"] == "team-A" })
        XCTAssertEqual(eventA.payload["source"], "linear")
        XCTAssertEqual(eventA.payload["team_name"], "Engineering")
        XCTAssertEqual(eventA.payload["cycle_id"], "cycle-1")
        XCTAssertEqual(eventA.payload["cycle_name"], "Sprint 42")
        XCTAssertEqual(eventA.payload["completed_pct"], "80.0")
        XCTAssertEqual(eventA.payload["days_remaining"], "3")
        XCTAssertEqual(eventA.payload["scope_count"], "15")
        XCTAssertEqual(eventA.signalType, .context, "cycle progress — state pulse, signal_type=.context")
        // ADR-010 regression — defensive (snapshot не несёт description).
        XCTAssertNil(eventA.payload["description"])
    }

    /// Plan-required: 0 cycles (empty teams array) → 0 cycle events emitted (silent).
    func testTick_NoActiveCycles_NoCycleEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        // Empty cycles snapshot — no team in-cycle.
        await provider.setBatch(LinearIssueBatch(
            issues: [],
            cursorMs: nil,
            transitions: [],
            workload: .empty,
            cycles: .empty
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        let result = await collector.performTick()
        XCTAssertEqual(result.cycleEventsEmitted, 0)

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        XCTAssertNil(stored.first { $0.payload["event_kind"] == "linear_cycle_progress" })
    }

    // MARK: - Phase 4.7.B (B-8) — presence_state.linear writer + attachments enrichment

    /// Plan-required: после tick'а presence_state.linear row существует с composite
    /// state (workload + cycles), все expected keys присутствуют, derivedMode=nil.
    func testTick_WritesLinearPresenceState() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let workload = LinearAssignedWorkloadSnapshot(
            startedCount: 3,
            topPriority: 2,  // "high"
            lastTouchedIdentifier: "LEA-77",
            lastTouchedTs: nowMs - 60_000
        )
        let teamA = makeTeamCycle(
            teamID: "team-A", teamName: "Engineering",
            cycleID: "cycle-1", cycleName: "Sprint 42",
            completedPct: 80.0, daysRemaining: 3, scopeCount: 15
        )
        let teamB = makeTeamCycle(
            teamID: "team-B", teamName: "Design",
            cycleID: "cycle-2", cycleName: "Iteration 7",
            completedPct: 50.0, daysRemaining: 7, scopeCount: 8
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [],
            cursorMs: nil,
            transitions: [],
            workload: workload,
            cycles: LinearCycleSnapshot(teams: [teamA, teamB], observedAtMs: nowMs)
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .linear, in: rawDB)
        }
        let row = try XCTUnwrap(presence, "presence_state.linear row должен существовать после tick'а")
        XCTAssertNil(row.derivedMode, "derivedMode=nil в Phase 4.7 (Phase 4.9 начнёт populate)")

        let state = row.state
        XCTAssertEqual(state["started_issues_count"] as? Int, 3)
        XCTAssertEqual(state["top_priority"] as? String, "high")
        XCTAssertEqual(state["last_touched_issue_id"] as? String, "LEA-77")
        XCTAssertEqual(state["last_touched_ts"] as? Int64, nowMs - 60_000)

        // current_cycle = первая team (team-A) per plan literal.
        let currentCycle = try XCTUnwrap(state["current_cycle"] as? [String: Any])
        XCTAssertEqual(currentCycle["team_id"] as? String, "team-A")
        XCTAssertEqual(currentCycle["cycle_name"] as? String, "Sprint 42")
        XCTAssertEqual(currentCycle["completed_pct"] as? Double, 80.0)
        XCTAssertEqual(currentCycle["days_remaining"] as? Int, 3)
        XCTAssertEqual(currentCycle["scope_count"] as? Int, 15)

        // all_team_cycles — array обоих team'ов (multi-team support).
        let allTeams = try XCTUnwrap(state["all_team_cycles"] as? [[String: Any]])
        XCTAssertEqual(allTeams.count, 2)
        XCTAssertEqual(allTeams[0]["team_id"] as? String, "team-A")
        XCTAssertEqual(allTeams[1]["team_id"] as? String, "team-B")
    }

    /// Plan-required: state JSON не должен содержать reserved content keys
    /// ("title" / "description" / "body") — defensive shape check.
    /// Caller responsibility — этот тест guards boundary.
    func testTick_LinearPresenceStateOmitsBodies() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        // Inject sentinel в title issue'а — но всё равно presence_state не должен
        // его содержать (build composite только из workload + cycles snapshots).
        let sentinelTitle = "SENSITIVE_LINEAR_TITLE_LEAK_xyz"
        let issue = LinearIssueSnapshot(
            issueKey: "LEA-99",
            title: sentinelTitle,
            status: "In Progress",
            project: "Leaf",
            teamKey: "LEA",
            updatedAtMs: 1_700_000_000_000
        )
        let provider = MockLinearGraphQLProvider()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        await provider.setBatch(LinearIssueBatch(
            issues: [issue],
            cursorMs: 1_700_000_000_000,
            transitions: [],
            workload: .empty,
            cycles: .empty
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .linear, in: rawDB)
        }
        let row = try XCTUnwrap(presence)
        let topLevelKeys = Set(row.state.keys)
        XCTAssertFalse(topLevelKeys.contains("title"),
                       "presence_state.linear не должен содержать 'title' top-level key")
        XCTAssertFalse(topLevelKeys.contains("description"),
                       "presence_state.linear не должен содержать 'description' top-level key")
        XCTAssertFalse(topLevelKeys.contains("body"),
                       "presence_state.linear не должен содержать 'body' top-level key")

        // Sentinel title из issue не должна leak'ать в state JSON (paranoid check).
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        XCTAssertFalse(serializedStr.contains(sentinelTitle),
                       "title issue не должен попасть в presence_state.linear JSON")
        // Используется значение nowMs из суток сегодня — не должно совпадать с
        // sentinel нигде; fallback assertion: snapshot present.
        _ = nowMs  // sanity hold
    }

    /// Pragmatic atomicity smoke: positive-path — events + offset + presence row
    /// land together после single performTick. См. также
    /// `DatabaseAtomicEventsAndOffsetTests.testWriteEventsOffsetAndPresenceAtomic`
    /// (B-0): тот тест locks rollback semantics на infrastructure уровне.
    func testTick_LinearPresenceStateUsesAtomicWrite() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = 1_750_000_000_000
        let issue = LinearIssueSnapshot(
            issueKey: "LEA-200",
            title: "Atomicity probe",
            status: "In Progress",
            project: "Leaf",
            teamKey: "LEA",
            updatedAtMs: cursorMs
        )
        let workload = LinearAssignedWorkloadSnapshot(
            startedCount: 1, topPriority: 1,
            lastTouchedIdentifier: "LEA-200", lastTouchedTs: cursorMs
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [issue],
            cursorMs: cursorMs,
            transitions: [],
            workload: workload,
            cycles: .empty
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        // 1) event landed.
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let issueEvents = stored.filter { $0.payload["issue_key"] == "LEA-200" }
        XCTAssertGreaterThanOrEqual(issueEvents.count, 1, "issue event должен быть persisted")

        // 2) offset advanced.
        let offset = try db.readOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: "linear:ws-1"
        )
        XCTAssertEqual(offset?.lastModifiedMs, cursorMs, "cursor должен advance к batch.cursorMs")

        // 3) presence row present.
        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .linear, in: rawDB)
        }
        let row = try XCTUnwrap(presence, "presence_state.linear должен быть persisted в той же транзакции")
        XCTAssertEqual(row.state["started_issues_count"] as? Int, 1)
        XCTAssertEqual(row.state["last_touched_issue_id"] as? String, "LEA-200")
    }

    /// Plan-required: makeEvent injects linked_* keys только при non-zero counts.
    /// Validates payload key omission convention для empty case.
    func testTick_IssueWithoutAttachments_NoLinkedKeysInPayload() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let issue = LinearIssueSnapshot(
            issueKey: "LEA-300",
            title: "Issue without attachments",
            status: "In Progress",
            project: "Leaf",
            teamKey: "LEA",
            updatedAtMs: 1_750_000_000_000
            // linkedGitHubPRCount / linkedSlackMessageCount / linkedAttachmentCount = 0 (defaults)
            // linkedGitHubTopRepo = nil (default)
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [issue],
            cursorMs: 1_750_000_000_000,
            transitions: [],
            workload: .empty,
            cycles: .empty
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let issueEvent = try XCTUnwrap(stored.first {
            $0.payload["issue_key"] == "LEA-300" && $0.payload["event_kind"] == "issue_updated"
        })
        XCTAssertNil(issueEvent.payload["linked_github_pr_count"],
                     "0 PRs → ключ должен отсутствовать")
        XCTAssertNil(issueEvent.payload["linked_github_top_repo"],
                     "nil topRepo → ключ должен отсутствовать")
        XCTAssertNil(issueEvent.payload["linked_slack_message_count"],
                     "0 Slack → ключ должен отсутствовать")
        XCTAssertNil(issueEvent.payload["linked_attachment_count"],
                     "0 attachments → ключ должен отсутствовать")
    }

    /// Plan-required: makeEvent injects linked_* keys when issue has populated counts.
    func testTick_IssueWithAttachments_LinkedKeysInPayload() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let issue = LinearIssueSnapshot(
            issueKey: "LEA-301",
            title: "Issue with attachments",
            status: "In Progress",
            project: "Leaf",
            teamKey: "LEA",
            updatedAtMs: 1_750_000_000_000,
            linkedGitHubPRCount: 2,
            linkedGitHubTopRepo: "octocat/leaf",
            linkedSlackMessageCount: 1,
            linkedAttachmentCount: 4
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [issue],
            cursorMs: 1_750_000_000_000,
            transitions: [],
            workload: .empty,
            cycles: .empty
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let issueEvent = try XCTUnwrap(stored.first {
            $0.payload["issue_key"] == "LEA-301" && $0.payload["event_kind"] == "issue_updated"
        })
        XCTAssertEqual(issueEvent.payload["linked_github_pr_count"], "2")
        XCTAssertEqual(issueEvent.payload["linked_github_top_repo"], "octocat/leaf")
        XCTAssertEqual(issueEvent.payload["linked_slack_message_count"], "1")
        XCTAssertEqual(issueEvent.payload["linked_attachment_count"], "4")
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
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()  // Phase 4.5 — не трогаем shared `tech.gundem.leaf` suite
        )

        await collector.start()
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms — даём loop'у проснуться 1-2 раза
        await collector.stop()

        // Provider не должен быть called (нет integration row → skip path).
        let calls = await provider.calls()
        XCTAssertEqual(calls.count, 0)
    }

    // MARK: - Phase 4.7.C — priority transitions

    /// Batch с одним priorityTransitions snap → tick emit'ит linear_priority_changed
    /// event с правильным payload shape (signal=action, raw int values, history_id).
    func testTickEmitsPriorityTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let prioritySnap = LinearPriorityTransitionSnapshot(
            issueKey: "LEA-1",
            historyId: "hist-prio-1",
            transitionAtMs: cursorMs,
            fromPriority: 3,
            toPriority: 1
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-1", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            priorityTransitions: [prioritySnap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let priorityEvent = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "linear_priority_changed" }
        )
        XCTAssertEqual(priorityEvent.payload["issue_key"], "LEA-1")
        XCTAssertEqual(priorityEvent.payload["history_id"], "hist-prio-1")
        XCTAssertEqual(priorityEvent.payload["from_priority"], "3")
        XCTAssertEqual(priorityEvent.payload["to_priority"], "1")
        XCTAssertEqual(priorityEvent.payload["source"], "linear")
        XCTAssertEqual(priorityEvent.signalType, .action)
    }

    /// Mixed batch: 2 added + 1 removed snap'а → 3 events с правильными kind'ами.
    func testTickEmitsLabelAddedAndRemovedEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snaps = [
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .added,
                labelId: "lbl-1", labelName: "bug"
            ),
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .added,
                labelId: "lbl-2", labelName: "p1"
            ),
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .removed,
                labelId: "lbl-3", labelName: "wontfix"
            )
        ]
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-200", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            labelTransitions: snaps
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let added = stored.filter { $0.payload["event_kind"] == "linear_label_added" }
        let removed = stored.filter { $0.payload["event_kind"] == "linear_label_removed" }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(Set(added.compactMap { $0.payload["label_id"] }), ["lbl-1", "lbl-2"])
        XCTAssertEqual(removed.first?.payload["label_id"], "lbl-3")
        XCTAssertEqual(removed.first?.payload["issue_key"], "LEA-200")
    }

    /// Phase 4.7.C — assignee event с bucket enum + no raw IDs leaked.
    func testTickEmitsAssigneeTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearAssigneeTransitionSnapshot(
            issueKey: "LEA-300",
            historyId: "hist-asg-1",
            transitionAtMs: cursorMs,
            bucket: .reassignedSelfToOther
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-300", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            assigneeTransitions: [snap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let asgn = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_assignee_changed" })
        XCTAssertEqual(asgn.payload["issue_key"], "LEA-300")
        XCTAssertEqual(asgn.payload["history_id"], "hist-asg-1")
        XCTAssertEqual(asgn.payload["bucket"], "reassigned_self_to_other")
        // ADR-010 sentinel: payload не должен содержать from/to ID полей вообще.
        XCTAssertNil(asgn.payload["from_assignee_id"], "raw IDs не покидают provider")
        XCTAssertNil(asgn.payload["to_assignee_id"])
    }

    /// Phase 4.7.C — cycle transition event с правильным payload (move scenario).
    func testTickEmitsCycleTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearCycleTransitionSnapshot(
            issueKey: "LEA-400", historyId: "hist-cyc-1",
            transitionAtMs: cursorMs,
            fromCycleId: "cyc-1", fromCycleName: "Sprint 41",
            toCycleId: "cyc-2", toCycleName: "Sprint 42"
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-400", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            cycleTransitions: [snap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let cyc = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_cycle_changed" })
        XCTAssertEqual(cyc.payload["issue_key"], "LEA-400")
        XCTAssertEqual(cyc.payload["from_cycle_id"], "cyc-1")
        XCTAssertEqual(cyc.payload["from_cycle_name"], "Sprint 41")
        XCTAssertEqual(cyc.payload["to_cycle_id"], "cyc-2")
        XCTAssertEqual(cyc.payload["to_cycle_name"], "Sprint 42")
    }

    /// Phase 4.7.C — cycle transition payload omits nil sides (added/removed).
    func testTickEmitsCycleTransitionEventWithOmittedNilSides() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        // "Added to cycle" — fromCycle nil, toCycle populated.
        let snap = LinearCycleTransitionSnapshot(
            issueKey: "LEA-401", historyId: "hist-cyc-add",
            transitionAtMs: cursorMs,
            fromCycleId: nil, fromCycleName: nil,
            toCycleId: "cyc-X", toCycleName: "Sprint X"
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-401", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            cycleTransitions: [snap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let cyc = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_cycle_changed" })
        XCTAssertNil(cyc.payload["from_cycle_id"], "nil from → ключ omitted")
        XCTAssertNil(cyc.payload["from_cycle_name"])
        XCTAssertEqual(cyc.payload["to_cycle_id"], "cyc-X")
        XCTAssertEqual(cyc.payload["to_cycle_name"], "Sprint X")
    }

    /// Phase 4.7.C — estimate transition event с правильным payload.
    func testTickEmitsEstimateTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearEstimateTransitionSnapshot(
            issueKey: "LEA-500", historyId: "hist-est-1",
            transitionAtMs: cursorMs,
            fromEstimate: 3.0, toEstimate: 5.0
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-500", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            estimateTransitions: [snap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let est = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_estimate_changed" })
        XCTAssertEqual(est.payload["issue_key"], "LEA-500")
        XCTAssertEqual(est.payload["history_id"], "hist-est-1")
        XCTAssertEqual(est.payload["from_estimate"], "3.0")
        XCTAssertEqual(est.payload["to_estimate"], "5.0")
    }

    /// Estimate added (nil → 5) — payload omits from_estimate.
    func testTickEmitsEstimateAddedEventWithOmittedFrom() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearEstimateTransitionSnapshot(
            issueKey: "LEA-501", historyId: "hist-est-add",
            transitionAtMs: cursorMs,
            fromEstimate: nil, toEstimate: 8.0
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-501", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs,
            estimateTransitions: [snap]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let est = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_estimate_changed" })
        XCTAssertNil(est.payload["from_estimate"], "nil from → omit ключа")
        XCTAssertEqual(est.payload["to_estimate"], "8.0")
    }

    /// Phase 4.7.C — ProjectUpdate authored event с правильным payload.
    func testTickEmitsProjectUpdateAuthoredEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let pu = LinearProjectUpdateSnapshot(
            updateId: "pu-1",
            createdAtMs: cursorMs,
            projectId: "proj-A", projectName: "Leaf",
            health: "onTrack"
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [],
            cursorMs: cursorMs,
            projectUpdates: [pu]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let pu2 = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_project_update_authored" })
        XCTAssertEqual(pu2.payload["update_id"], "pu-1")
        XCTAssertEqual(pu2.payload["project_id"], "proj-A")
        XCTAssertEqual(pu2.payload["project_name"], "Leaf")
        XCTAssertEqual(pu2.payload["health"], "onTrack")
    }

    /// Empty projectUpdates → no event.
    func testTickDoesNotEmitProjectUpdateEventWhenEmpty() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await provider.setBatch(LinearIssueBatch(issues: [], cursorMs: cursorMs))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        XCTAssertNil(
            stored.first { $0.payload["event_kind"] == "linear_project_update_authored" }
        )
    }

    /// Phase 4.7.C — Document edited event с правильным payload.
    func testTickEmitsDocumentEditedEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let doc = LinearDocumentSnapshot(
            documentId: "doc-1",
            updatedAtMs: nowMs,
            projectId: "proj-A", projectName: "Leaf",
            title: "Q4 Roadmap"
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [], cursorMs: nowMs,
            documents: [doc]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let de = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_document_edited" })
        XCTAssertEqual(de.payload["document_id"], "doc-1")
        XCTAssertEqual(de.payload["title"], "Q4 Roadmap")
        XCTAssertEqual(de.payload["project_id"], "proj-A")
        XCTAssertEqual(de.payload["project_name"], "Leaf")
    }

    /// Standalone document — без project info.
    func testTickEmitsDocumentEditedEventStandalone() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let doc = LinearDocumentSnapshot(
            documentId: "doc-2",
            updatedAtMs: nowMs,
            projectId: nil, projectName: nil,
            title: "Standalone"
        )
        await provider.setBatch(LinearIssueBatch(
            issues: [], cursorMs: nowMs,
            documents: [doc]
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let de = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_document_edited" })
        XCTAssertEqual(de.payload["document_id"], "doc-2")
        XCTAssertEqual(de.payload["title"], "Standalone")
        XCTAssertNil(de.payload["project_id"])
        XCTAssertNil(de.payload["project_name"])
    }

    /// Empty priorityTransitions → no priority event emitted.
    func testTickDoesNotEmitPriorityEventWhenEmpty() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await provider.setBatch(LinearIssueBatch(
            issues: [
                LinearIssueSnapshot(
                    issueKey: "LEA-1", title: "Topic", status: "In Progress",
                    project: "", teamKey: "LEA", updatedAtMs: cursorMs
                )
            ],
            cursorMs: cursorMs
        ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        XCTAssertNil(
            stored.first { $0.payload["event_kind"] == "linear_priority_changed" },
            "no priority transitions in batch → no event emitted"
        )
    }
}
