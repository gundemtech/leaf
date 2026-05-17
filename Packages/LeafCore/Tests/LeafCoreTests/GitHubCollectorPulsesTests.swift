// Phase 4.7.B — pulses (notifications, review queue, my open PRs, actions runs)
// + start/stop lifecycle. Split from GitHubCollectorTests.swift for type_body_length.

import XCTest
import os

@testable import LeafCore

final class GitHubCollectorPulsesTests: XCTestCase {
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

    // MARK: - Phase 4.7.B-1 — notifications pulse

    /// Provider stub returns a non-empty summary → tick должен emit'ить
    /// `github_notifications_pulse` event с total_unread + reason_*_count keys.
    /// Signal type — `.context` (не `.action` — это state pulse, не user action).
    func testTick_EmitsNotificationsPulse() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        // Empty events batch + non-empty notifications → tick должен emit'ить только pulse.
        await provider.setBatch(.empty)
        let pulseObservedAt: Int64 = 1_700_000_000_000
        await provider.setNotificationsSummary(
            GitHubNotificationsSummary(
                totalUnread: 4,
                byReason: [
                    "review_requested": 2,
                    "mention": 1,
                    "comment": 1,
                ],
                observedAtMs: pulseObservedAt
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        let result = await collector.performTick()
        XCTAssertFalse(result.skipped)
        let notifCalls = await provider.notificationsCalls()
        XCTAssertEqual(notifCalls, 1, "fetchNotifications вызвался ровно раз")

        // Read all events; ровно один с event_kind=github_notifications_pulse.
        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
            ))
        // Empty batch → нет .action events; только .context pulses.
        XCTAssertEqual(
            stored.filter { $0.signalType == .action }.count, 0,
            "empty batch → нет .action events")
        let pulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "gh_notifications_pulse" },
            "ожидался github_notifications_pulse event"
        )
        XCTAssertEqual(pulse.signalType, .context, "pulse — state event, signal_type=.context")
        XCTAssertEqual(pulse.payload["source"], "github")
        XCTAssertEqual(pulse.payload["total_unread"], "4")
        XCTAssertEqual(pulse.payload["reason_review_requested_count"], "2")
        XCTAssertEqual(pulse.payload["reason_mention_count"], "1")
        XCTAssertEqual(pulse.payload["reason_comment_count"], "1")
        XCTAssertNotNil(pulse.payload["observed_at_ms"], "observed_at_ms всегда populated")
    }

    // MARK: - Phase 4.7.B-2 — review queue + my open PRs pulses

    /// Provider stubs return non-empty summaries → tick должен emit'ить два pulse
    /// event'а: `pr_awaiting_review_count` (с `top_repo`) и `my_open_pr_count`.
    /// Both signal_type=.context (state pulses, не user actions).
    func testTick_EmitsPRAwaitingReviewAndMyOpenPRs() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        await provider.setBatch(.empty)
        let observedAt: Int64 = 1_700_000_000_000
        await provider.setReviewQueueSummary(
            GitHubReviewQueueSummary(
                count: 5, topRepo: "octocat/leaf", observedAtMs: observedAt
            ))
        await provider.setMyOpenPRsSummary(
            GitHubMyOpenPRsSummary(
                count: 7, observedAtMs: observedAt
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        let result = await collector.performTick()
        XCTAssertFalse(result.skipped)
        let reviewCalls = await provider.reviewQueueCalls()
        let myOpenCalls = await provider.myOpenPRsCalls()
        XCTAssertEqual(reviewCalls, 1, "fetchPRsAwaitingReview вызвался ровно раз")
        XCTAssertEqual(myOpenCalls, 1, "fetchMyOpenPRs вызвался ровно раз")

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
            ))

        let reviewPulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "gh_pr_awaiting_review_count" },
            "ожидался pr_awaiting_review_count event"
        )
        XCTAssertEqual(reviewPulse.signalType, .context)
        XCTAssertEqual(reviewPulse.payload["source"], "github")
        XCTAssertEqual(reviewPulse.payload["count"], "5")
        XCTAssertEqual(reviewPulse.payload["top_repo"], "octocat/leaf")
        XCTAssertNotNil(reviewPulse.payload["observed_at_ms"])

        let openPulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "gh_my_open_pr_count" },
            "ожидался my_open_pr_count event"
        )
        XCTAssertEqual(openPulse.signalType, .context)
        XCTAssertEqual(openPulse.payload["source"], "github")
        XCTAssertEqual(openPulse.payload["count"], "7")
        XCTAssertNil(openPulse.payload["top_repo"], "my_open_pr_count не несёт top_repo")
        XCTAssertNotNil(openPulse.payload["observed_at_ms"])
    }

    /// `top_repo` payload key omitted при `count==0` (review queue empty).
    /// Отличает "ничего не ждёт" от "ничего не fetched" / future error states.
    func testTick_EmptyReviewQueueOmitsTopRepoKey() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        await provider.setBatch(.empty)
        // Default mock summaries — empty (.empty(nowMs:)) — count=0, topRepo=nil.

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
            ))
        let reviewPulse = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_awaiting_review_count" })
        XCTAssertEqual(reviewPulse.payload["count"], "0")
        XCTAssertNil(reviewPulse.payload["top_repo"], "topRepo=nil → key omitted entirely")
    }

    // MARK: - Phase 4.7.B-3 — actions runs

    /// Provider stub returns 2 runs → 2 `actions_run_initiated` action events emitted.
    /// `signal_type=.action` (discrete user action), payload содержит run_id + repo +
    /// workflow_name + event + status. ADR-010 fields (head_commit.message / run.name)
    /// — provider их не set'ит в snapshot, collector их не emit'ит.
    func testTick_EmitsActionsRunInitiatedEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        await provider.setBatch(.empty)
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setActionsRuns([
            GitHubActionsRunSnapshot(
                runID: 100, repo: "octocat/leaf",
                workflowName: "Release", event: "push",
                status: "completed", conclusion: "success",
                createdAtMs: baseMs, headBranch: "main"
            ),
            GitHubActionsRunSnapshot(
                runID: 101, repo: "octocat/leaf",
                workflowName: "Ci", event: "pull_request",
                status: "in_progress", conclusion: nil,
                createdAtMs: baseMs + 1000, headBranch: "feature/x"
            ),
        ])

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )

        let result = await collector.performTick()
        XCTAssertFalse(result.skipped)
        let runsCalls = await provider.actionsRunsCalls()
        XCTAssertEqual(runsCalls, 1, "fetchActionsRunsForActor вызвался ровно раз")

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 10_000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 10_000) / 1000)
            ))
        let runEvents = stored.filter { $0.payload["event_kind"] == "gh_actions_run_initiated" }
        XCTAssertEqual(runEvents.count, 2, "2 runs → 2 actions_run_initiated events")

        // Все run-events должны иметь signal_type=.action (discrete user action).
        for ev in runEvents {
            XCTAssertEqual(ev.signalType, .action, "actions_run_initiated — signal_type=.action")
            XCTAssertEqual(ev.payload["source"], "github")
            XCTAssertNotNil(ev.payload["run_id"])
            XCTAssertNotNil(ev.payload["repo"])
            XCTAssertNotNil(ev.payload["workflow_name"])
        }

        // First run — completed/success, со всеми optional fields.
        let releaseRun = try XCTUnwrap(runEvents.first { $0.payload["run_id"] == "100" })
        XCTAssertEqual(releaseRun.payload["repo"], "octocat/leaf")
        XCTAssertEqual(releaseRun.payload["workflow_name"], "Release")
        XCTAssertEqual(releaseRun.payload["event"], "push")
        XCTAssertEqual(releaseRun.payload["status"], "completed")
        XCTAssertEqual(releaseRun.payload["conclusion"], "success")
        XCTAssertEqual(releaseRun.payload["head_branch"], "main")

        // Second run — in_progress, conclusion=nil → ключ omitted из payload.
        let ciRun = try XCTUnwrap(runEvents.first { $0.payload["run_id"] == "101" })
        XCTAssertEqual(ciRun.payload["status"], "in_progress")
        XCTAssertNil(ciRun.payload["conclusion"], "conclusion=nil → key omitted entirely")
        XCTAssertEqual(ciRun.payload["head_branch"], "feature/x")
    }
}
