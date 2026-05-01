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
        private(set) var notificationsCallCount: Int = 0
        private(set) var reviewQueueCallCount: Int = 0
        private(set) var myOpenPRsCallCount: Int = 0
        private(set) var actionsRunsCallCount: Int = 0
        private(set) var actionsRunsReposReceived: [[String]] = []
        private(set) var actionsRunsSinceReceived: [Int64] = []
        private var batchToReturn: GitHubEventBatch = .empty
        private var notificationsSummaryToReturn: GitHubNotificationsSummary?
        private var reviewQueueSummaryToReturn: GitHubReviewQueueSummary?
        private var myOpenPRsSummaryToReturn: GitHubMyOpenPRsSummary?
        private var actionsRunsToReturn: [GitHubActionsRunSnapshot] = []

        func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
            sinceCalls.append(since)
            loginCalls.append(login)
            return batchToReturn
        }

        // Phase 4.7.B-1 — default returns empty pulse если test не setNotificationsSummary;
        // позволяет существующим тестам компилиться без модификации (они проверяют
        // events from setBatch(_:), pulse — orthogonal channel).
        func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary {
            notificationsCallCount += 1
            return notificationsSummaryToReturn ?? .empty(
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }

        // Phase 4.7.B-2 — defaults к `.empty` для backwards compat с existing тестами,
        // которые сосредоточены на batch events / cursor flow.
        func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary {
            reviewQueueCallCount += 1
            return reviewQueueSummaryToReturn ?? .empty(
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }

        func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary {
            myOpenPRsCallCount += 1
            return myOpenPRsSummaryToReturn ?? .empty(
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }

        // Phase 4.7.B-3 — defaults к `[]` для backwards compat. setActionsRuns(_:)
        // переопределяет результат для тестов, exercise'ующих action runs explicitly.
        // Existing тесты используют signalType=.action filter assuming только batch
        // events; default empty actions runs preserves этот invariant.
        func fetchActionsRunsForActor(
            accessToken: String, login: String, repos: [String], since: Int64
        ) async throws -> [GitHubActionsRunSnapshot] {
            actionsRunsCallCount += 1
            actionsRunsReposReceived.append(repos)
            actionsRunsSinceReceived.append(since)
            return actionsRunsToReturn
        }

        func setBatch(_ batch: GitHubEventBatch) {
            self.batchToReturn = batch
        }

        func setNotificationsSummary(_ summary: GitHubNotificationsSummary) {
            self.notificationsSummaryToReturn = summary
        }

        func setReviewQueueSummary(_ summary: GitHubReviewQueueSummary) {
            self.reviewQueueSummaryToReturn = summary
        }

        func setMyOpenPRsSummary(_ summary: GitHubMyOpenPRsSummary) {
            self.myOpenPRsSummaryToReturn = summary
        }

        func setActionsRuns(_ runs: [GitHubActionsRunSnapshot]) {
            self.actionsRunsToReturn = runs
        }

        func calls() -> [Int64?] { sinceCalls }
        func logins() -> [String] { loginCalls }
        func notificationsCalls() -> Int { notificationsCallCount }
        func reviewQueueCalls() -> Int { reviewQueueCallCount }
        func myOpenPRsCalls() -> Int { myOpenPRsCallCount }
        func actionsRunsCalls() -> Int { actionsRunsCallCount }
        func actionsRunsRepos() -> [[String]] { actionsRunsReposReceived }
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
        XCTAssertEqual(result.cursorAdvancedMs, cursorMs)

        // Structural assertion на batch events: filter by signalType=.action.
        // Pulses (notifications / pr_awaiting_review_count / my_open_pr_count) идут
        // как .context — не пересекаются. Forward-compat: следующие B-tasks могут
        // добавлять new pulse'ы без bumping числовых counts здесь.
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(cursorMs - 10_000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(cursorMs + 10_000) / 1000)
        ))
        let actionEvents = stored.filter { $0.signalType == .action }
        XCTAssertEqual(actionEvents.count, 3, "3 batch events from fetchEvents")

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

    /// Phase 4.6.A.1 — latency-fields из snapshot'а должны доезжать до events.payload.
    /// Snapshot с `cycleSeconds=10800` → payload содержит ключ `cycle_seconds = "10800"`;
    /// snapshot без latency → ключ отсутствует (не пустая строка).
    func testTickEncodesCycleAndReviewDelayInPayload() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(GitHubEventBatch(
            events: [
                GitHubEventSnapshot(
                    eventID: "merged-1", eventKind: "pr_merged", repoFullName: "octocat/leaf",
                    title: "feat: x", number: 42, sha: nil, branch: nil,
                    createdAtMs: baseMs,
                    cycleSeconds: 10_800, reviewDelaySeconds: nil
                ),
                GitHubEventSnapshot(
                    eventID: "review-1", eventKind: "review_submitted", repoFullName: "octocat/leaf",
                    title: "feat: y", number: 50, sha: nil, branch: nil,
                    createdAtMs: baseMs + 1000,
                    cycleSeconds: nil, reviewDelaySeconds: 600
                ),
                GitHubEventSnapshot(
                    eventID: "push-1", eventKind: "commit_pushed", repoFullName: "octocat/leaf",
                    title: "wip", number: nil, sha: "abc", branch: "main",
                    createdAtMs: baseMs + 2000
                    // cycleSeconds / reviewDelaySeconds — defaults nil
                )
            ],
            cursorMs: baseMs + 2000
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
        ))
        // Structural assertion: 3 .action events from batch + N .context pulses.
        // Filter by signalType — forward-compat across future B-tasks.
        let actionEvents = stored.filter { $0.signalType == .action }
        XCTAssertEqual(actionEvents.count, 3, "3 batch events with signalType=.action")

        let merged = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "pr_merged" })
        XCTAssertEqual(merged.payload["cycle_seconds"], "10800")
        XCTAssertNil(merged.payload["review_delay_seconds"], "non-review event не должен иметь review_delay_seconds key")

        let review = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "review_submitted" })
        XCTAssertEqual(review.payload["review_delay_seconds"], "600")
        XCTAssertNil(review.payload["cycle_seconds"], "review event не несёт cycle key")

        let push = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "commit_pushed" })
        XCTAssertNil(push.payload["cycle_seconds"], "snapshot.cycleSeconds=nil → key отсутствует, не \"\"")
        XCTAssertNil(push.payload["review_delay_seconds"])
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

    /// Phase 4.7.A — `metadata` dict из snapshot'а прокачивается в payload,
    /// reserved keys (`source`/`event_kind`/etc) защищены от override.
    func testTickEncodesMetadataFieldsInPayload() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(GitHubEventBatch(
            events: [
                GitHubEventSnapshot(
                    eventID: "rel-1", eventKind: "release_published",
                    repoFullName: "octocat/leaf",
                    title: "", number: nil, sha: nil, branch: nil,
                    createdAtMs: baseMs,
                    metadata: [
                        "tag_name": "v1.0.0",
                        "action": "published",
                        // Попытка override reserved key — должна быть проигнорирована.
                        "event_kind": "OVERRIDE_ATTEMPT"
                    ]
                ),
                GitHubEventSnapshot(
                    eventID: "tag-1", eventKind: "tag_created",
                    repoFullName: "octocat/leaf",
                    title: "", number: nil, sha: nil, branch: nil,
                    createdAtMs: baseMs + 1000,
                    metadata: ["tag_name": "v1.1.0"]
                ),
                GitHubEventSnapshot(
                    eventID: "push-1", eventKind: "commit_pushed",
                    repoFullName: "octocat/leaf",
                    title: "wip", number: nil, sha: "abc", branch: "main",
                    createdAtMs: baseMs + 2000
                    // metadata defaults nil → no extra payload keys
                )
            ],
            cursorMs: baseMs + 2000
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
        ))

        let release = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "release_published" })
        XCTAssertEqual(release.payload["tag_name"], "v1.0.0")
        XCTAssertEqual(release.payload["action"], "published")
        XCTAssertEqual(release.payload["event_kind"], "release_published",
                       "reserved key event_kind не overridable через metadata")

        let tag = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "tag_created" })
        XCTAssertEqual(tag.payload["tag_name"], "v1.1.0")

        let push = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "commit_pushed" })
        XCTAssertNil(push.payload["tag_name"], "snapshot.metadata=nil → нет лишних ключей в payload")
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
        await provider.setNotificationsSummary(GitHubNotificationsSummary(
            totalUnread: 4,
            byReason: [
                "review_requested": 2,
                "mention": 1,
                "comment": 1
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
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
        ))
        // Empty batch → нет .action events; только .context pulses.
        XCTAssertEqual(stored.filter { $0.signalType == .action }.count, 0,
                       "empty batch → нет .action events")
        let pulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "github_notifications_pulse" },
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
        await provider.setReviewQueueSummary(GitHubReviewQueueSummary(
            count: 5, topRepo: "octocat/leaf", observedAtMs: observedAt
        ))
        await provider.setMyOpenPRsSummary(GitHubMyOpenPRsSummary(
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

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
        ))

        let reviewPulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "pr_awaiting_review_count" },
            "ожидался pr_awaiting_review_count event"
        )
        XCTAssertEqual(reviewPulse.signalType, .context)
        XCTAssertEqual(reviewPulse.payload["source"], "github")
        XCTAssertEqual(reviewPulse.payload["count"], "5")
        XCTAssertEqual(reviewPulse.payload["top_repo"], "octocat/leaf")
        XCTAssertNotNil(reviewPulse.payload["observed_at_ms"])

        let openPulse = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "my_open_pr_count" },
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

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: TimeInterval(Date().timeIntervalSince1970 + 60))
        ))
        let reviewPulse = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "pr_awaiting_review_count" })
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
            )
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

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 10_000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 10_000) / 1000)
        ))
        let runEvents = stored.filter { $0.payload["event_kind"] == "actions_run_initiated" }
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
