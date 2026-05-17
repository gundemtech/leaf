// Phase 4.7.A — linear_comment_authored + 4.7.B (B-6/B-7/B-8) — workload pulse,
// cycle progress per team, presence_state.linear writer, attachments enrichment,
// and start/stop lifecycle. Split from LinearCollectorTests.swift for
// type_body_length / file_length.

import XCTest
import os
import class GRDB.Row

@testable import LeafCore

final class LinearCollectorPhase47BTests: XCTestCase {
    private typealias Support = LinearCollectorTestSupport
    private typealias MockLinearGraphQLProvider = LinearCollectorTestSupport.MockLinearGraphQLProvider

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

    private func insertFreshIntegration(
        db: Database, workspaceID: String = "ws-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, workspaceID: workspaceID, expiresAt: expiresAt)
    }

    private func makeIsolatedSuiteName() -> String {
        Support.makeIsolatedSuiteName()
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
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

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let pulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "linear_assigned_workload_pulse" },
            "pulse должен emit'иться даже на empty workload"
        )
        XCTAssertEqual(pulse.payload["started_count"], "0")
        XCTAssertEqual(
            pulse.payload["top_priority"], "none",
            "empty workload → top_priority=\"none\" (всегда present, не omitted)")
        XCTAssertNil(
            pulse.payload["last_touched_identifier"],
            "nil identifier → key omitted")
        XCTAssertNil(
            pulse.payload["last_touched_ts_ms"],
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
        endsAtMs: Int64 = 1_780_000_000_000,  // в будущем
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
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
        await provider.setBatch(
            LinearIssueBatch(
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
        await provider.setBatch(
            LinearIssueBatch(
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
        XCTAssertFalse(
            topLevelKeys.contains("title"),
            "presence_state.linear не должен содержать 'title' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("description"),
            "presence_state.linear не должен содержать 'description' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("body"),
            "presence_state.linear не должен содержать 'body' top-level key")

        // Sentinel title из issue не должна leak'ать в state JSON (paranoid check).
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        XCTAssertFalse(
            serializedStr.contains(sentinelTitle),
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
        await provider.setBatch(
            LinearIssueBatch(
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
        let stored = try db.events(
            in: DateInterval(
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        let issueEvent = try XCTUnwrap(
            stored.first {
                $0.payload["issue_key"] == "LEA-300" && $0.payload["event_kind"] == "issue_updated"
            })
        XCTAssertNil(
            issueEvent.payload["linked_github_pr_count"],
            "0 PRs → ключ должен отсутствовать")
        XCTAssertNil(
            issueEvent.payload["linked_github_top_repo"],
            "nil topRepo → ключ должен отсутствовать")
        XCTAssertNil(
            issueEvent.payload["linked_slack_message_count"],
            "0 Slack → ключ должен отсутствовать")
        XCTAssertNil(
            issueEvent.payload["linked_attachment_count"],
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
        await provider.setBatch(
            LinearIssueBatch(
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

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        let issueEvent = try XCTUnwrap(
            stored.first {
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
}
