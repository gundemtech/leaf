// Phase 4.7.B-4/B-5 — check_runs_status per pushed commit + contributions calendar
// + presence_state.github snapshot writes. Split from GitHubCollectorTests.swift
// for type_body_length.

import XCTest
import os

@testable import LeafCore

// swiftlint:disable force_unwrapping

final class GitHubCollectorPresenceStateTests: XCTestCase {
    private typealias Support = GitHubCollectorTestSupport
    private typealias MockGitHubAPIProvider = GitHubCollectorTestSupport.MockGitHubAPIProvider

    private var tempDir: URL!
    private var dbURL: URL!
    private var logger: Logger { GitHubCollectorTestSupport.logger }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-github-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertFreshIntegration(
        db: Database, login: String = "octocat", expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, login: login, expiresAt: expiresAt)
    }

    // MARK: - Phase 4.7.B-4 — check_runs_status per pushed commit

    /// 2 push events с разными shas → 2 fetchCheckRunsForCommit calls, 2
    /// `check_runs_status` events emitted (signal_type=.context). Bucket counts
    /// from summary прокачиваются в payload as-is.
    func testTick_EmitsCheckRunsStatusForEachPush() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "push-1", eventKind: "gh_commit_pushed",
                        repoFullName: "octocat/leaf",
                        title: "feat: x", number: nil, sha: "aaa111",
                        branch: "main", createdAtMs: baseMs
                    ),
                    GitHubEventSnapshot(
                        eventID: "push-2", eventKind: "gh_commit_pushed",
                        repoFullName: "octocat/other",
                        title: "fix: y", number: nil, sha: "bbb222",
                        branch: "main", createdAtMs: baseMs + 1000
                    ),
                ],
                cursorMs: baseMs + 1000
            ))
        // Per-(repo, sha) check-runs summaries.
        await provider.setCheckRuns(
            repo: "octocat/leaf", sha: "aaa111",
            summary: GitHubCheckRunsSummary(total: 4, success: 2, failure: 1, inProgress: 1, neutral: 0)
        )
        await provider.setCheckRuns(
            repo: "octocat/other", sha: "bbb222",
            summary: GitHubCheckRunsSummary(total: 3, success: 0, failure: 0, inProgress: 0, neutral: 3)
        )

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        _ = await collector.performTick()

        let checkCalls = await provider.checkRunsCalls()
        XCTAssertEqual(checkCalls, 2, "2 unique pushed (repo, sha) → 2 fetchCheckRunsForCommit calls")
        let args = await provider.checkRunsArgs()
        let pairs = Set(args.map { "\($0.repo)|\($0.sha)" })
        XCTAssertEqual(pairs, Set(["octocat/leaf|aaa111", "octocat/other|bbb222"]))

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
            ))
        let checkEvents = stored.filter { $0.payload["event_kind"] == "gh_check_runs_status" }
        XCTAssertEqual(checkEvents.count, 2, "2 push pairs → 2 check_runs_status events")
        for ev in checkEvents {
            XCTAssertEqual(ev.signalType, .context, "check_runs_status — state pulse, signal_type=.context")
            XCTAssertEqual(ev.payload["source"], "github")
            XCTAssertNotNil(ev.payload["repo"])
            XCTAssertNotNil(ev.payload["sha"])
            XCTAssertNotNil(ev.payload["total"])
            XCTAssertNotNil(ev.payload["success"])
            XCTAssertNotNil(ev.payload["failure"])
            XCTAssertNotNil(ev.payload["in_progress"])
            XCTAssertNotNil(ev.payload["neutral"])
            XCTAssertNotNil(ev.payload["observed_at_ms"])
        }

        let leafEvent = try XCTUnwrap(checkEvents.first { $0.payload["sha"] == "aaa111" })
        XCTAssertEqual(leafEvent.payload["repo"], "octocat/leaf")
        XCTAssertEqual(leafEvent.payload["total"], "4")
        XCTAssertEqual(leafEvent.payload["success"], "2")
        XCTAssertEqual(leafEvent.payload["failure"], "1")
        XCTAssertEqual(leafEvent.payload["in_progress"], "1")
        XCTAssertEqual(leafEvent.payload["neutral"], "0")

        let otherEvent = try XCTUnwrap(checkEvents.first { $0.payload["sha"] == "bbb222" })
        XCTAssertEqual(otherEvent.payload["repo"], "octocat/other")
        XCTAssertEqual(otherEvent.payload["total"], "3")
        XCTAssertEqual(otherEvent.payload["neutral"], "3")
    }

    /// Без commit_pushed events в batch → 0 fetchCheckRunsForCommit calls + 0
    /// check_runs_status events. Tick остальное (notifications / review queue /
    /// my open PRs / actions runs pulses) всё равно работает.
    func testTick_NoPushEvents_NoCheckRunsCalls() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        // Batch только non-push events.
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "pr-1", eventKind: "gh_pr_opened",
                        repoFullName: "octocat/leaf",
                        title: "feat", number: 42, sha: nil, branch: nil,
                        createdAtMs: baseMs
                    ),
                    GitHubEventSnapshot(
                        eventID: "issue-1", eventKind: "gh_issue_closed",
                        repoFullName: "octocat/leaf",
                        title: "bug", number: 7, sha: nil, branch: nil,
                        createdAtMs: baseMs + 1000
                    ),
                ],
                cursorMs: baseMs + 1000
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        _ = await collector.performTick()

        let checkCalls = await provider.checkRunsCalls()
        XCTAssertEqual(checkCalls, 0, "non-push batch → 0 fetchCheckRunsForCommit calls")

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
            ))
        let checkEvents = stored.filter { $0.payload["event_kind"] == "gh_check_runs_status" }
        XCTAssertEqual(checkEvents.count, 0, "0 push pairs → 0 check_runs_status events")
    }

    // MARK: - Phase 4.7.B-5 — contributions calendar + presence_state.github

    /// Helper для UTC-aligned `Date` для testов day-boundary cooldown'а.
    /// Возвращает midnight UTC + offsetSeconds.
    private func utcDate(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: components)!
    }

    /// Two ticks одного дня → fetchContributionsCalendar called только один раз.
    /// Cooldown gate работает.
    func testTick_FetchesContributionsOncePerDay() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        // expiresAt в далёком будущем — refresher выходит на no-op даже когда мы
        // подаём `now` в прошлом (utcDate fixture'ы для day-boundary теста).
        try insertFreshIntegration(
            db: db,
            expiresAt: utcDate(year: 2030, month: 1, day: 1)
        )

        let provider = MockGitHubAPIProvider()
        await provider.setBatch(.empty)

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        let day1Noon = utcDate(year: 2026, month: 5, day: 1, hour: 12)
        let day1Evening = utcDate(year: 2026, month: 5, day: 1, hour: 22)

        _ = await collector.performTick(now: day1Noon)
        _ = await collector.performTick(now: day1Evening)

        let calls = await provider.contributionsCalls()
        XCTAssertEqual(calls, 1, "two ticks same UTC day → 1 fetchContributionsCalendar call")
    }

    /// Tick на day+1 → fetchContributionsCalendar called второй раз.
    /// Day-boundary triggers re-fetch.
    func testTick_FetchesContributionsAcrossDayBoundary() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(
            db: db,
            expiresAt: utcDate(year: 2030, month: 1, day: 1)
        )

        let provider = MockGitHubAPIProvider()
        await provider.setBatch(.empty)

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        let day1 = utcDate(year: 2026, month: 5, day: 1, hour: 12)
        let day2 = utcDate(year: 2026, month: 5, day: 2, hour: 8)

        _ = await collector.performTick(now: day1)
        _ = await collector.performTick(now: day2)

        let calls = await provider.contributionsCalls()
        XCTAssertEqual(calls, 2, "ticks across UTC day boundary → 2 fetchContributionsCalendar calls")
    }

    /// После tick'а presence_state.github row существует с composite state, все
    /// 8 plan-required keys присутствуют, derivedMode=nil.
    func testTick_WritesPresenceStateRow() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        // Push event → check_runs reduction → latest_push_check_status="success".
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "push-1", eventKind: "gh_commit_pushed",
                        repoFullName: "octocat/leaf", title: "wip",
                        number: nil, sha: "deadbeef", branch: "main",
                        createdAtMs: baseMs
                    )
                ],
                cursorMs: baseMs
            ))
        await provider.setNotificationsSummary(
            GitHubNotificationsSummary(
                totalUnread: 4,
                byReason: ["review_requested": 2, "mention": 1, "comment": 1],
                observedAtMs: baseMs
            ))
        await provider.setReviewQueueSummary(
            GitHubReviewQueueSummary(
                count: 3, topRepo: "octocat/leaf", observedAtMs: baseMs
            ))
        await provider.setMyOpenPRsSummary(
            GitHubMyOpenPRsSummary(
                count: 5, observedAtMs: baseMs
            ))
        await provider.setCheckRuns(
            repo: "octocat/leaf", sha: "deadbeef",
            summary: GitHubCheckRunsSummary(total: 2, success: 2, failure: 0, inProgress: 0, neutral: 0)
        )
        await provider.setContributionsCalendar(
            GitHubContributionsCalendar(
                totalContributions: 423, todayCount: 7, weeks: []
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        _ = await collector.performTick()

        // Read back presence_state.github row.
        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .github, in: rawDB)
        }
        let row = try XCTUnwrap(presence, "presence_state.github row должен существовать после tick'а")
        XCTAssertNil(row.derivedMode, "derivedMode=nil в Phase 4.7 (Phase 4.9 начнёт populate)")

        // All 8 plan-required keys present.
        let state = row.state
        XCTAssertEqual(state["notifications_unread"] as? Int, 4)
        let byReason = try XCTUnwrap(state["notifications_by_reason"] as? [String: Int])
        XCTAssertEqual(byReason["review_requested"], 2)
        XCTAssertEqual(byReason["mention"], 1)
        XCTAssertEqual(byReason["comment"], 1)
        XCTAssertEqual(state["prs_awaiting_my_review"] as? Int, 3)
        XCTAssertEqual(state["prs_awaiting_top_repo"] as? String, "octocat/leaf")
        XCTAssertEqual(state["my_open_prs"] as? Int, 5)
        XCTAssertEqual(
            state["latest_push_check_status"] as? String, "success",
            "2 success / 0 failure / 0 in_progress → success bucket")
        XCTAssertEqual(state["contributions_today"] as? Int, 7)
        // active_repos_count = 0 (events table пуста до этого tick'а — derive
        // query видит just-inserted push, но окно 7 дней назад отработало
        // на прошлом empty состоянии). Если будет 1 (включая current push),
        // это тоже acceptable — invariant: ключ присутствует и Int.
        XCTAssertNotNil(state["active_repos_count"] as? Int)
    }

    /// ADR-010 regression: presence_state JSON не должен содержать reserved
    /// content keys ("title" / "body" / "message") — defensive shape check.
    /// Caller responsibility — этот тест guards boundary.
    func testTick_PresenceStateOmitsRedactedFields() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        // Even if we inject sentinel into "title-bearing" fields, those don't
        // propagate into presence_state — we only push counts/repo identifiers.
        let sentinelTitle = "SENSITIVE_TITLE_LEAK_xyz"
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "pr-1", eventKind: "gh_pr_opened",
                        repoFullName: "octocat/leaf",
                        title: sentinelTitle, number: 42, sha: nil, branch: nil,
                        createdAtMs: 1_700_000_000_000
                    )
                ],
                cursorMs: 1_700_000_000_000
            ))
        await provider.setReviewQueueSummary(
            GitHubReviewQueueSummary(
                count: 1, topRepo: "octocat/leaf", observedAtMs: 1_700_000_000_000
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        // Read raw JSON и ассерт что reserved content keys не появились.
        // Используем raw stateJSON column через PresenceStateWriter.read (parsed dict
        // даёт нам keys()) — boundary check.
        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .github, in: rawDB)
        }
        let row = try XCTUnwrap(presence)
        let topLevelKeys = Set(row.state.keys)
        XCTAssertFalse(
            topLevelKeys.contains("title"),
            "presence_state не должен содержать 'title' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("body"),
            "presence_state не должен содержать 'body' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("message"),
            "presence_state не должен содержать 'message' top-level key")

        // Sentinel string из event title не должна leak'ать в стейт через какое-либо
        // поле (paranoid check — guards против accidental forwarding).
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        XCTAssertFalse(
            serializedStr.contains(sentinelTitle),
            "title content не должен попасть в presence_state JSON")
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
// swiftlint:enable force_unwrapping
