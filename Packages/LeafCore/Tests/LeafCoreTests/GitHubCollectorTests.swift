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
        private(set) var checkRunsCallCount: Int = 0
        private(set) var checkRunsArgsReceived: [(repo: String, sha: String)] = []
        private(set) var contributionsCallCount: Int = 0
        private var batchToReturn: GitHubEventBatch = .empty
        private var notificationsSummaryToReturn: GitHubNotificationsSummary?
        private var reviewQueueSummaryToReturn: GitHubReviewQueueSummary?
        private var myOpenPRsSummaryToReturn: GitHubMyOpenPRsSummary?
        private var actionsRunsToReturn: [GitHubActionsRunSnapshot] = []
        // Per-(repo, sha) check-runs response keyed by "repo|sha"; default — `.empty`.
        private var checkRunsByKey: [String: GitHubCheckRunsSummary] = [:]
        private var contributionsCalendarToReturn: GitHubContributionsCalendar = .empty

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

        // Phase 4.7.B-4 — defaults к `.empty` для backwards compat. setCheckRuns(_:_:_:)
        // переопределяет per-(repo, sha) — другие pairs всё равно return `.empty`.
        func fetchCheckRunsForCommit(
            accessToken: String, repo: String, sha: String
        ) async throws -> GitHubCheckRunsSummary {
            checkRunsCallCount += 1
            checkRunsArgsReceived.append((repo: repo, sha: sha))
            return checkRunsByKey["\(repo)|\(sha)"] ?? .empty
        }

        // Phase 4.7.B-5 — contributions calendar; defaults к `.empty` (todayCount=0).
        // Используется только когда collector сам решает fetch (cooldown gate).
        func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar {
            contributionsCallCount += 1
            return contributionsCalendarToReturn
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

        func setCheckRuns(repo: String, sha: String, summary: GitHubCheckRunsSummary) {
            self.checkRunsByKey["\(repo)|\(sha)"] = summary
        }

        func setContributionsCalendar(_ calendar: GitHubContributionsCalendar) {
            self.contributionsCalendarToReturn = calendar
        }

        func calls() -> [Int64?] { sinceCalls }
        func logins() -> [String] { loginCalls }
        func notificationsCalls() -> Int { notificationsCallCount }
        func reviewQueueCalls() -> Int { reviewQueueCallCount }
        func myOpenPRsCalls() -> Int { myOpenPRsCallCount }
        func actionsRunsCalls() -> Int { actionsRunsCallCount }
        func actionsRunsRepos() -> [[String]] { actionsRunsReposReceived }
        func checkRunsCalls() -> Int { checkRunsCallCount }
        func checkRunsArgs() -> [(repo: String, sha: String)] { checkRunsArgsReceived }
        func contributionsCalls() -> Int { contributionsCallCount }
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
                    eventID: "e1", eventKind: "gh_commit_pushed", repoFullName: "octocat/leaf",
                    title: "Initial commit", number: nil, sha: "abc123", branch: "main",
                    createdAtMs: cursorMs - 2000
                ),
                GitHubEventSnapshot(
                    eventID: "e2", eventKind: "gh_pr_opened", repoFullName: "octocat/leaf",
                    title: "Add feature X", number: 42, sha: nil, branch: nil,
                    createdAtMs: cursorMs - 1000
                ),
                GitHubEventSnapshot(
                    eventID: "e3", eventKind: "gh_issue_closed", repoFullName: "octocat/other",
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
                    eventID: "merged-1", eventKind: "gh_pr_merged", repoFullName: "octocat/leaf",
                    title: "feat: x", number: 42, sha: nil, branch: nil,
                    createdAtMs: baseMs,
                    cycleSeconds: 10_800, reviewDelaySeconds: nil
                ),
                GitHubEventSnapshot(
                    eventID: "review-1", eventKind: "gh_pr_review_submitted", repoFullName: "octocat/leaf",
                    title: "feat: y", number: 50, sha: nil, branch: nil,
                    createdAtMs: baseMs + 1000,
                    cycleSeconds: nil, reviewDelaySeconds: 600
                ),
                GitHubEventSnapshot(
                    eventID: "push-1", eventKind: "gh_commit_pushed", repoFullName: "octocat/leaf",
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

        let merged = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_merged" })
        XCTAssertEqual(merged.payload["cycle_seconds"], "10800")
        XCTAssertNil(merged.payload["review_delay_seconds"], "non-review event не должен иметь review_delay_seconds key")

        let review = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_review_submitted" })
        XCTAssertEqual(review.payload["review_delay_seconds"], "600")
        XCTAssertNil(review.payload["cycle_seconds"], "review event не несёт cycle key")

        let push = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_commit_pushed" })
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
                eventID: "e1", eventKind: "gh_commit_pushed", repoFullName: "octocat/leaf",
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
                    eventID: "rel-1", eventKind: "gh_release_published",
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
                    eventID: "tag-1", eventKind: "gh_tag_created",
                    repoFullName: "octocat/leaf",
                    title: "", number: nil, sha: nil, branch: nil,
                    createdAtMs: baseMs + 1000,
                    metadata: ["tag_name": "v1.1.0"]
                ),
                GitHubEventSnapshot(
                    eventID: "push-1", eventKind: "gh_commit_pushed",
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

        let release = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_release_published" })
        XCTAssertEqual(release.payload["tag_name"], "v1.0.0")
        XCTAssertEqual(release.payload["action"], "published")
        XCTAssertEqual(release.payload["event_kind"], "gh_release_published",
                       "reserved key event_kind не overridable через metadata")

        let tag = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_tag_created" })
        XCTAssertEqual(tag.payload["tag_name"], "v1.1.0")

        let push = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_commit_pushed" })
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

        let stored = try db.events(in: DateInterval(
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

    // MARK: - Phase 4.7.B-4 — check_runs_status per pushed commit

    /// 2 push events с разными shas → 2 fetchCheckRunsForCommit calls, 2
    /// `check_runs_status` events emitted (signal_type=.context). Bucket counts
    /// from summary прокачиваются в payload as-is.
    func testTick_EmitsCheckRunsStatusForEachPush() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(GitHubEventBatch(
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
                )
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

        let stored = try db.events(in: DateInterval(
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
        await provider.setBatch(GitHubEventBatch(
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
                )
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

        let stored = try db.events(in: DateInterval(
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
        await provider.setBatch(GitHubEventBatch(
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
        await provider.setNotificationsSummary(GitHubNotificationsSummary(
            totalUnread: 4,
            byReason: ["review_requested": 2, "mention": 1, "comment": 1],
            observedAtMs: baseMs
        ))
        await provider.setReviewQueueSummary(GitHubReviewQueueSummary(
            count: 3, topRepo: "octocat/leaf", observedAtMs: baseMs
        ))
        await provider.setMyOpenPRsSummary(GitHubMyOpenPRsSummary(
            count: 5, observedAtMs: baseMs
        ))
        await provider.setCheckRuns(
            repo: "octocat/leaf", sha: "deadbeef",
            summary: GitHubCheckRunsSummary(total: 2, success: 2, failure: 0, inProgress: 0, neutral: 0)
        )
        await provider.setContributionsCalendar(GitHubContributionsCalendar(
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
        XCTAssertEqual(state["latest_push_check_status"] as? String, "success",
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
        await provider.setBatch(GitHubEventBatch(
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
        await provider.setReviewQueueSummary(GitHubReviewQueueSummary(
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
        XCTAssertFalse(topLevelKeys.contains("title"),
                       "presence_state не должен содержать 'title' top-level key")
        XCTAssertFalse(topLevelKeys.contains("body"),
                       "presence_state не должен содержать 'body' top-level key")
        XCTAssertFalse(topLevelKeys.contains("message"),
                       "presence_state не должен содержать 'message' top-level key")

        // Sentinel string из event title не должна leak'ать в стейт через какое-либо
        // поле (paranoid check — guards против accidental forwarding).
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        XCTAssertFalse(serializedStr.contains(sentinelTitle),
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

    // MARK: - Track-1 D1 — payload key emission

    /// Full commit message captured as `body` — NOT truncated to first line.
    /// Track-1 D1 §6 amendment: full message on-device via BodyCap.
    func testTick_FullCommitMessage_NotTruncatedToFirstLine_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        let fullBody = "Subject only\n\nLong body paragraph explaining the context and rationale."
        await provider.setBatch(GitHubEventBatch(
            events: [GitHubEventSnapshot(
                eventID: "push-body-1", eventKind: "gh_commit_pushed",
                repoFullName: "octocat/leaf",
                title: "Subject only",
                number: nil, sha: "abc123", branch: "main",
                createdAtMs: baseMs,
                body: fullBody,
                bodyTruncated: false
            )],
            cursorMs: baseMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
        ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_commit_pushed" })
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.body], fullBody,
                       "full commit message должен быть в payload.body")
        XCTAssertTrue(event.payload[Schema.EventPayloadKeys.body]?.contains("Long body paragraph") == true,
                      "body содержит multi-line content")
        XCTAssertNil(event.payload[Schema.EventPayloadKeys.bodyTruncated],
                     "bodyTruncated absent когда не truncated")
    }

    /// PRMetadata fields всех 6 ключей присутствуют в payload.
    func testTick_PRMetadataPayloadKeys_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_100
        let meta = PRMetadata(
            filesCount: 3, additions: 50, deletions: 10,
            requestedReviewers: ["alice"],
            mentionCount: 1, linkCount: 0
        )
        await provider.setBatch(GitHubEventBatch(
            events: [GitHubEventSnapshot(
                eventID: "pr-meta-1", eventKind: "gh_pr_opened",
                repoFullName: "octocat/leaf",
                title: "feat: new feature",
                number: 10, sha: nil, branch: nil,
                createdAtMs: baseMs,
                prMetadata: meta
            )],
            cursorMs: baseMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
        ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.filesCount], "3")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.additions], "50")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.deletions], "10")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.mentionCount], "1")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.linkCount], "0")
        let reviewersJson = try XCTUnwrap(event.payload[Schema.EventPayloadKeys.requestedReviewersJson])
        XCTAssertTrue(reviewersJson.contains("alice"), "requested_reviewers_json содержит reviewer login")
    }

    /// Inline images parsed from PR body → attachments_json в payload.
    func testTick_InlineImagesParsedFromBody_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_200
        let screenshotAttachment = AttachmentMeta(name: "screenshot.png", mime: "image/png", sizeBytes: nil)
        await provider.setBatch(GitHubEventBatch(
            events: [GitHubEventSnapshot(
                eventID: "pr-attach-1", eventKind: "gh_pr_opened",
                repoFullName: "octocat/leaf",
                title: "fix: UI bug",
                number: 20, sha: nil, branch: nil,
                createdAtMs: baseMs,
                attachments: [screenshotAttachment]
            )],
            cursorMs: baseMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
        ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        let attachmentsJson = try XCTUnwrap(event.payload[Schema.EventPayloadKeys.attachmentsJson],
                                             "attachments_json должен быть в payload")
        XCTAssertTrue(attachmentsJson.contains("screenshot.png"), "attachments_json содержит filename")
        // JSONEncoder escapes "/" → "\/" in JSON; check for "image" + "png" separately.
        XCTAssertTrue(attachmentsJson.contains("image") && attachmentsJson.contains("png"),
                      "attachments_json содержит mime type (image/png, possibly JSON-escaped)")
    }

    // MARK: - Track-3 D2 Task 4 — gh_* rename + 7 new hot-tier event_kinds

    /// Snapshot eventKind already prefixed `gh_*` (post-D2 contract — moat parser
    /// emits canonical via GitHubEventKindKey.rawValue) → payload preserves it.
    /// Sanity check that makeEvent doesn't strip / re-map the prefix.
    func testCollectorEmitsGhPrefixedEventKinds() {
        let snapshot = GitHubEventSnapshot(
            eventID: "e1",
            eventKind: GitHubEventKindKey.prOpened.rawValue,
            repoFullName: "owner/foo",
            title: "Hello",
            number: 1,
            sha: nil,
            branch: nil,
            createdAtMs: 1_000,
            body: "PR body text",
            bodyTruncated: false
        )
        let event = GitHubCollector.makeEvent(snapshot: snapshot)
        XCTAssertEqual(event.payload["event_kind"], "gh_pr_opened")
    }

    /// 7 new hot-tier event_kinds (Task 4) — payload preserves event_kind +
    /// new metadata keys flow through via metadata merge (not shadowed).
    func testCollectorEmitsHotTierNewEventKinds() {
        let cases: [(GitHubEventKindKey, [String: String])] = [
            (.issueLocked, [:]),
            (.issueUnlocked, [:]),
            (.workflowManualTriggered, ["workflow_name": "release.yml", "workflow_ref": "refs/heads/main"]),
            (.deploymentCreated, ["deployment_environment": "production"]),
            (.deploymentStatusChanged, ["deployment_environment": "production", "deployment_state": "success"]),
            (.repoCreated, ["repository_visibility": "public"]),
            (.repoForked, ["forkee_full_name": "fork/foo"])
        ]
        for (kind, metadata) in cases {
            let snapshot = GitHubEventSnapshot(
                eventID: "e",
                eventKind: kind.rawValue,
                repoFullName: "owner/foo",
                title: "",
                number: nil,
                sha: nil,
                branch: nil,
                createdAtMs: 1,
                metadata: metadata.isEmpty ? nil : metadata
            )
            let event = GitHubCollector.makeEvent(snapshot: snapshot)
            XCTAssertEqual(event.payload["event_kind"], kind.rawValue)
            for (k, v) in metadata {
                XCTAssertEqual(event.payload[k], v, "Expected metadata key \(k) preserved for \(kind.rawValue)")
            }
        }
    }

    /// `gh_pr_review_submitted` carries `pr_review_state` discriminator
    /// ("approved" / "changes_requested" / "commented" / "dismissed").
    /// Schema.EventPayloadKeys.prReviewState is the canonical key.
    func testPRReviewSubmittedCarriesStateDiscriminator() {
        let snapshot = GitHubEventSnapshot(
            eventID: "e",
            eventKind: GitHubEventKindKey.prReviewSubmitted.rawValue,
            repoFullName: "owner/foo",
            title: "",
            number: 42,
            sha: nil,
            branch: nil,
            createdAtMs: 1,
            metadata: ["pr_review_state": "approved"]
        )
        let event = GitHubCollector.makeEvent(snapshot: snapshot)
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.prReviewState], "approved")
    }

    /// Reserved-keys guard предотвращает shadowing: snapshot.metadata с "body"/"additions" ключами
    /// не может перезаписать body/additions из snapshot.body/prMetadata.
    func testTick_ReservedKeysGuard_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_300
        let realBody = "real body content — should appear"
        let meta = PRMetadata(
            filesCount: 5, additions: 42, deletions: 1,
            requestedReviewers: [], mentionCount: 0, linkCount: 0
        )
        await provider.setBatch(GitHubEventBatch(
            events: [GitHubEventSnapshot(
                eventID: "guard-1", eventKind: "gh_pr_opened",
                repoFullName: "octocat/leaf",
                title: "test",
                number: 99, sha: nil, branch: nil,
                createdAtMs: baseMs,
                // metadata tries to shadow `body` and `additions` keys
                metadata: ["body": "metadata-shadow", "additions": "999"],
                body: realBody,
                bodyTruncated: false,
                prMetadata: meta
            )],
            cursorMs: baseMs
        ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
        ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        // Real body wins over metadata shadow.
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.body], realBody,
                       "real body из snapshot.body должен присутствовать")
        XCTAssertFalse(event.payload.values.contains("metadata-shadow"),
                       "metadata shadow не должен появляться в payload")
        // Real additions from prMetadata wins over metadata shadow.
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.additions], "42",
                       "real additions из prMetadata должны быть в payload")
        XCTAssertFalse(event.payload.values.contains("999"),
                       "metadata additions shadow не должен перезаписать реальное значение")
    }
}
