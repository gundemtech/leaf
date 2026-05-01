//
//  GitHubCollector.swift
//  LeafCore
//
//  Phase 4.3 — GitHub REST events polling collector. Раз в `intervalSec`:
//  1. Читает `integrations` row (provider=.github). Нет → skip.
//  2. `refresher.refreshIfNeeded(now:)` — refresh access token если истекает.
//     На `.refreshDenied` (invalid_grant) refresher уже сделал deleteIntegration
//     + UserDefaults flag + DistributedNotification → UI surface'ит "Reconnect needed".
//  3. `provider.fetchEvents(token, login, since:)` — REST GET /users/<login>/events.
//     `since` = stored `lastModifiedMs` (max `created_at` от прошлого tick'а);
//     bootstrap → `nil` → provider использует первую страницу feed'а (~90д max).
//  4. Map результат в `[RawEvent]` с `signal_type=.action`, `payload.source=github`.
//  5. Atomic write через `writeEventsAndOffset(events:offset:)` — events + cursor
//     в одной транзакции. Cursor = `batch.cursorMs` (newest createdAt).
//

import Foundation
import os

public actor GitHubCollector {
    /// Phase 4.7.B-3 — top-N most-recently-pushed repos cap для bounded fan-out
    /// `actions/runs` polling. N=10 → ≤10 HTTP calls per tick поверх baseline events
    /// fetch; conservative под 5000/hr primary rate-limit (12 ticks/hr × 10 calls = 120/hr).
    /// TODO(B-5+): activeReposCap may need to drop to 5-7 once check_runs and
    /// contributions land — verify GitHub REST budget headroom (B-4 add ≤K
    /// check-runs calls per tick where K = unique pushed shas; B-5 daily
    /// contributions GraphQL — separate budget, не per-tick).
    private static let activeReposCap = 10
    /// Phase 4.7.B-3 — sliding window для derive активных repos из `events` table.
    /// 7 дней — достаточно чтобы поймать недельный rhythm проекта без false-positive
    /// от старого ad-hoc activity. Конфигурабельно (constant) если потребуется tuning.
    private static let activeReposLookbackDays = 7

    private let database: Database
    private let provider: any GitHubAPIProvider
    private let refresher: GitHubTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Phase 4.7.B-5 — in-memory cooldown gate для daily contributions GraphQL.
    /// `"yyyy-MM-dd"` UTC; refetch fires только когда day rolls over. Reset на
    /// app restart — допустимо: at-most one redundant fetch per launch (REST
    /// `/graphql` cost ≈ negligible под 5000pts/hr secondary limit).
    private var lastContributionsFetchDay: String?
    /// Phase 4.7.B-5 — cached value across ticks. Updated только когда fresh
    /// calendar fetched в этом tick'е (cooldown gate didn't fire). Sticky:
    /// если today's day rolls over но fetch упал, prev value остаётся в
    /// `presence_state` — non-zero false-positive менее плох, чем silent drop.
    private var lastContributionsToday: Int = 0

    public init(
        database: Database,
        provider: any GitHubAPIProvider,
        refresher: GitHubTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        restartTriggerName: String = GitHubOAuthEndpoints.integrationChangedNotificationName,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.restartTriggerName = restartTriggerName
        self.logger = logger
    }

    public func start() {
        guard loopTask == nil else { return }
        let name = NSNotification.Name(restartTriggerName)
        notifyToken = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.kickTick() }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info("GitHubCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        if let t = notifyToken {
            DistributedNotificationCenter.default().removeObserver(t)
            notifyToken = nil
        }
        logger.info("GitHubCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsProcessed: Int
        public let cursorAdvancedMs: Int64?
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .github)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → refresher уже сделал
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch GitHubTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — GitHub disconnected: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 3. Read cursor. workspaceID per Phase 4.3 = "github:<login>" → используем напрямую.
        // workspaceName хранит raw login (без префикса) — это путь /users/<login>/events.
        let sourceID = refreshed.workspaceID
        let login = refreshed.workspaceName
        let stored: CollectorOffset?
        do {
            stored = try database.readOffset(
                collectorID: CollectorID.githubPolling,
                sourceID: sourceID
            )
        } catch {
            logger.error("readOffset failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        let since: Int64? = stored?.lastModifiedMs

        // 4. Fetch.
        let batch: GitHubEventBatch
        do {
            batch = try await provider.fetchEvents(
                accessToken: refreshed.accessToken,
                login: login,
                since: since
            )
        } catch {
            logger.error("fetchEvents failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 5. Map events.
        var events = batch.events.map { Self.makeEvent(snapshot: $0) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // 5a. Phase 4.7.B-1 — notifications pulse. Failure must NOT block events
        // tick: provider already returns `.empty(nowMs:)` on non-200 / parse failure,
        // но сетевая ошибка throw'ит — wrap'им в do/catch + emit empty pulse, чтобы
        // observability не пропадала между tick'ами.
        let notifSummary: GitHubNotificationsSummary
        do {
            notifSummary = try await provider.fetchNotifications(accessToken: refreshed.accessToken)
        } catch {
            logger.error("fetchNotifications failed: \(String(describing: error), privacy: .public)")
            notifSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makeNotificationsPulseEvent(summary: notifSummary, nowMs: nowMs))

        // 5b. Phase 4.7.B-2 — review queue + my open PRs pulse. Each fetch wrapped
        // в свой do/catch — независимый graceful degrade. Always emit пульсы
        // даже при failure (counts=0, top_repo omitted) — observability discipline.
        let reviewQueueSummary: GitHubReviewQueueSummary
        do {
            reviewQueueSummary = try await provider.fetchPRsAwaitingReview(
                accessToken: refreshed.accessToken, login: login
            )
        } catch {
            logger.error("fetchPRsAwaitingReview failed: \(String(describing: error), privacy: .public)")
            reviewQueueSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makePRAwaitingReviewCountEvent(summary: reviewQueueSummary, nowMs: nowMs))

        let myOpenPRsSummary: GitHubMyOpenPRsSummary
        do {
            myOpenPRsSummary = try await provider.fetchMyOpenPRs(
                accessToken: refreshed.accessToken, login: login
            )
        } catch {
            logger.error("fetchMyOpenPRs failed: \(String(describing: error), privacy: .public)")
            myOpenPRsSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makeMyOpenPRCountEvent(summary: myOpenPRsSummary, nowMs: nowMs))

        // 5c. Phase 4.7.B-3 — actions/runs feed для top-N most-recently-pushed repos.
        // Derive активные repos из existing `events` table — bounded fan-out N HTTP
        // calls per tick (N = `Self.activeReposCap`). DB query failure → empty list,
        // не блокируем tick. `since` = nowMs - intervalSec*1000 → fetch только runs
        // initiated after last tick window (graceful approximation last-tick boundary).
        let activeReposSinceMs = nowMs - Int64(Self.activeReposLookbackDays) * 24 * 3600 * 1000
        let activeRepos: [String]
        do {
            activeRepos = try database.queryActiveGitHubRepos(
                sinceMs: activeReposSinceMs,
                limit: Self.activeReposCap
            )
        } catch {
            logger.error("queryActiveGitHubRepos failed: \(String(describing: error), privacy: .public)")
            activeRepos = []
        }
        let runsSinceMs = nowMs - Int64(intervalSec * 1000)
        let actionsRuns: [GitHubActionsRunSnapshot]
        do {
            actionsRuns = try await provider.fetchActionsRunsForActor(
                accessToken: refreshed.accessToken,
                login: login,
                repos: activeRepos,
                since: runsSinceMs
            )
        } catch {
            logger.error("fetchActionsRunsForActor failed: \(String(describing: error), privacy: .public)")
            actionsRuns = []
        }
        for run in actionsRuns {
            events.append(Self.makeActionsRunInitiatedEvent(snapshot: run))
        }

        // 5d. Phase 4.7.B-4 — check_runs aggregate per HEAD commit, push-triggered.
        // Bounded cost: K HTTP calls = K unique (repo, sha) pairs across все
        // commit_pushed snapshots в этом tick'е. Empty pushes → 0 calls (skipped
        // entirely). Iterate `batch.events` (snapshots) — preserves repo + sha
        // напрямую, не rely на string lookup в payload. Dedup via Set<String>
        // (`repo|sha`) — handles dual shape: stripped feed → 1 sha per push,
        // full webhook → N shas per push. Per-(repo,sha) failures (404 / parse)
        // → provider returns `.empty`, мы всё равно emit pulse (observability:
        // "у HEAD commit'а check-runs нет/недоступны").
        var seenPairs = Set<String>()
        var pushedPairs: [(repo: String, sha: String)] = []
        for snapshot in batch.events {
            guard snapshot.eventKind == "commit_pushed" else { continue }
            let repo = snapshot.repoFullName
            guard let sha = snapshot.sha, !sha.isEmpty, !repo.isEmpty else { continue }
            let key = "\(repo)|\(sha)"
            if seenPairs.insert(key).inserted {
                pushedPairs.append((repo: repo, sha: sha))
            }
        }
        // Latest push check-run status — собираем для presence_state.github.
        // pushedPairs приходит в том порядке, в котором мы итерировали batch.events
        // (REST events DESC by created_at → first pair = most recent push).
        // Берём first non-nil bucket reduction; nil если push events не было.
        var latestPushCheckStatus: String? = nil

        for pair in pushedPairs {
            let summary: GitHubCheckRunsSummary
            do {
                summary = try await provider.fetchCheckRunsForCommit(
                    accessToken: refreshed.accessToken,
                    repo: pair.repo,
                    sha: pair.sha
                )
            } catch {
                logger.error("fetchCheckRunsForCommit failed \(pair.repo, privacy: .public)/\(pair.sha, privacy: .public): \(String(describing: error), privacy: .public)")
                summary = .empty
            }
            events.append(Self.makeCheckRunsStatusEvent(
                repo: pair.repo, sha: pair.sha, summary: summary, nowMs: nowMs
            ))
            if latestPushCheckStatus == nil {
                // Reduce summary → status string. Severity-ordered: failure > in_progress > success.
                if summary.failure > 0 {
                    latestPushCheckStatus = "failure"
                } else if summary.inProgress > 0 {
                    latestPushCheckStatus = "in_progress"
                } else if summary.success > 0 {
                    latestPushCheckStatus = "success"
                }
                // total=0 / только neutral → leave nil (no actionable CI signal).
            }
        }

        // 5e. Phase 4.7.B-5 — daily contributions calendar. NOT emitted as event;
        // только cooldown-gated update of `lastContributionsToday` для
        // presence_state.github. Cooldown — in-memory `"yyyy-MM-dd"` UTC,
        // resets на app restart (acceptable: at-most 1 redundant fetch per launch).
        let utcDayFormatter = DateFormatter()
        utcDayFormatter.calendar = Calendar(identifier: .gregorian)
        utcDayFormatter.timeZone = TimeZone(identifier: "UTC")
        utcDayFormatter.dateFormat = "yyyy-MM-dd"
        utcDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let todayString = utcDayFormatter.string(from: now)
        if lastContributionsFetchDay != todayString {
            do {
                let calendar = try await provider.fetchContributionsCalendar(
                    accessToken: refreshed.accessToken
                )
                lastContributionsToday = calendar.todayCount
                lastContributionsFetchDay = todayString
            } catch {
                logger.error("fetchContributionsCalendar failed: \(String(describing: error), privacy: .public)")
                // Cooldown НЕ advance — retry next tick same day. lastContributionsToday
                // оставляем previous value (sticky).
            }
        }

        // 6. Build presence_state.github composite snapshot.
        // ADR-010 boundary: только counts / repo identifiers / status enums.
        // No titles / bodies / message subjects попадают в state JSON.
        // JSONSerialization не принимает Swift Optional — nil поля сериализуем
        // как NSNull (поле присутствует с явно null значением), не омитим.
        // Это позволяет downstream readers различать "ключ отсутствует, поле
        // не отслеживается" от "поле известно, значение null" — важный сигнал
        // для presence broadcast / merged snapshot rendering в Phase 5.
        let githubPresence: [String: Any] = [
            "notifications_unread": notifSummary.totalUnread,
            "notifications_by_reason": notifSummary.byReason,
            "prs_awaiting_my_review": reviewQueueSummary.count,
            "prs_awaiting_top_repo": reviewQueueSummary.topRepo.map { $0 as Any } ?? NSNull(),
            "my_open_prs": myOpenPRsSummary.count,
            "latest_push_check_status": latestPushCheckStatus.map { $0 as Any } ?? NSNull(),
            "contributions_today": lastContributionsToday,
            "active_repos_count": activeRepos.count
        ]

        // 7. Atomic write — events + offset + presence_state в одной транзакции.
        // Если batch пуст — cursor НЕ двигается (retry next tick на том же since).
        // Если batch не пуст — cursor = batch.cursorMs (max createdAt).
        let advancedCursor = batch.cursorMs ?? since
        let offset = CollectorOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: advancedCursor ?? nowMs,
            updatedMs: nowMs
        )
        do {
            try database.writeEventsOffsetAndPresence(
                events,
                offset: offset,
                presence: (.github, githubPresence, nil),
                nowMs: nowMs
            )
        } catch {
            logger.error("persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        if !events.isEmpty {
            logger.info("tick wrote \(events.count, privacy: .public) events, cursor=\(offset.lastModifiedMs, privacy: .public)")
        }
        return TickResult(
            skipped: false,
            eventsProcessed: events.count,
            cursorAdvancedMs: advancedCursor
        )
    }

    /// Phase 4.7.B-1 — `github_notifications_pulse` state event. Эмитится КАЖДЫЙ tick
    /// (даже при empty inbox) — нулевой count всё равно signal: "пользователь дочистил
    /// inbox". `signal_type=.context` (state pulse, не user action).
    /// Reasons распакованы в top-level keys (`reason_review_requested_count`) для
    /// query-friendly доступа без nested JSON parsing на read-side.
    static func makeNotificationsPulseEvent(
        summary: GitHubNotificationsSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "github_notifications_pulse",
            "total_unread": String(summary.totalUnread),
            "observed_at_ms": String(nowMs)
        ]
        // Top-level fields для query-friendly access (избегаем nested JSON в payload).
        for (reason, count) in summary.byReason {
            payload["reason_\(reason)_count"] = String(count)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `pr_awaiting_review_count` state event. Эмитится каждый tick.
    /// `signal_type=.context` (state pulse). `top_repo` поле omitted при `count==0`
    /// или `topRepo==nil` — отличает "нет данных" от "owner/repo:0".
    static func makePRAwaitingReviewCountEvent(
        summary: GitHubReviewQueueSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "pr_awaiting_review_count",
            "count": String(summary.count),
            "observed_at_ms": String(nowMs)
        ]
        if let topRepo = summary.topRepo {
            payload["top_repo"] = topRepo
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-3 — `actions_run_initiated` action event per snapshot.
    /// `signal_type=.action` (discrete action — юзер запустил CI run), не `.context`.
    /// Timestamp = run's `created_at` (когда GitHub registered run start), не nowMs —
    /// синхронизируется с реальным moment of action для downstream timeline accuracy.
    /// ADR-010: `head_commit.message` / run `name` (часто equals commit subject) /
    /// `output.title` — НЕ persisted. Только public-safe metadata: workflow file slug,
    /// trigger event, status/conclusion enum, head branch.
    static func makeActionsRunInitiatedEvent(snapshot: GitHubActionsRunSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "actions_run_initiated",
            "run_id": String(snapshot.runID),
            "repo": snapshot.repo,
            "workflow_name": snapshot.workflowName,
            "event": snapshot.event,
            "status": snapshot.status,
            "created_at_ms": String(snapshot.createdAtMs)
        ]
        // Только non-nil поля — отличает "completed→success" от "in_progress" (no
        // conclusion yet) на read-side без nullable parsing.
        if let conclusion = snapshot.conclusion {
            payload["conclusion"] = conclusion
        }
        if let branch = snapshot.headBranch {
            payload["head_branch"] = branch
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-4 — `check_runs_status` state event per (repo, sha) pair.
    /// `signal_type=.context` (state pulse — current CI status of HEAD commit,
    /// не discrete user action). Timestamp = `nowMs` (when collector observed),
    /// не `created_at` of run (this is aggregate snapshot across N runs).
    /// ADR-010: ни `name` of check-run, ни `output.title`/`output.summary`/
    /// `output.text` — provider их не parses, collector их не emit'ит. Только
    /// 5 aggregate counts (total + 4 buckets) + repo + sha identifiers.
    static func makeCheckRunsStatusEvent(
        repo: String, sha: String, summary: GitHubCheckRunsSummary, nowMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": "check_runs_status",
            "repo": repo,
            "sha": sha,
            "total": String(summary.total),
            "success": String(summary.success),
            "failure": String(summary.failure),
            "in_progress": String(summary.inProgress),
            "neutral": String(summary.neutral),
            "observed_at_ms": String(nowMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `my_open_pr_count` state event. Эмитится каждый tick.
    /// `signal_type=.context` (state pulse).
    static func makeMyOpenPRCountEvent(
        summary: GitHubMyOpenPRsSummary, nowMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": "my_open_pr_count",
            "count": String(summary.count),
            "observed_at_ms": String(nowMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    private static func makeEvent(snapshot: GitHubEventSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": snapshot.eventKind,
            "repo": snapshot.repoFullName,
            "title": snapshot.title,
            "number": snapshot.number.map(String.init) ?? "",
            "sha": snapshot.sha ?? "",
            "branch": snapshot.branch ?? ""
        ]
        // Phase 4.6.A.1 — latency fields. Только non-nil → ключ присутствует;
        // отсутствие ключа в payload отличает "не знаем" от "0 секунд".
        if let cycle = snapshot.cycleSeconds {
            payload["cycle_seconds"] = String(cycle)
        }
        if let delay = snapshot.reviewDelaySeconds {
            payload["review_delay_seconds"] = String(delay)
        }
        // Phase 4.7.A — per-event-kind extension fields. Reserved baseline keys
        // ("source"/"event_kind"/"repo"/"title"/"number"/"sha"/"branch"/
        // "cycle_seconds"/"review_delay_seconds") cannot be overridden via metadata
        // — guards против accidental shadowing. Other keys merge in.
        if let metadata = snapshot.metadata {
            let reserved: Set<String> = [
                "source", "event_kind", "repo", "title", "number", "sha", "branch",
                "cycle_seconds", "review_delay_seconds"
            ]
            for (key, value) in metadata where !reserved.contains(key) {
                payload[key] = value
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    private func kickTick() async {
        await performTick()
    }

    private func runLoop() async {
        await sleep(seconds: min(intervalSec, 5))
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
