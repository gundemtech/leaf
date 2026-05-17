//
//  GitHubCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration moved
//  out of GitHubCollector.swift. Pure relocation; no behavioural change.
//

import Foundation

extension GitHubCollector {
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
        // gh_commit_pushed snapshots в этом tick'е. Empty pushes → 0 calls (skipped
        // entirely). Iterate `batch.events` (snapshots) — preserves repo + sha
        // напрямую, не rely на string lookup в payload. Dedup via Set<String>
        // (`repo|sha`) — handles dual shape: stripped feed → 1 sha per push,
        // full webhook → N shas per push. Per-(repo,sha) failures (404 / parse)
        // → provider returns `.empty`, мы всё равно emit pulse (observability:
        // "у HEAD commit'а check-runs нет/недоступны").
        var seenPairs = Set<String>()
        var pushedPairs: [(repo: String, sha: String)] = []
        for snapshot in batch.events {
            guard snapshot.eventKind == GitHubEventKindKey.commitPushed.rawValue else { continue }
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
                logger.error(
                    "fetchCheckRunsForCommit failed \(pair.repo, privacy: .public)/\(pair.sha, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                summary = .empty
            }
            events.append(
                Self.makeCheckRunsStatusEvent(
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
            "active_repos_count": activeRepos.count,
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
            logger.info(
                "tick wrote \(events.count, privacy: .public) events, cursor=\(offset.lastModifiedMs, privacy: .public)"
            )
        }
        return TickResult(
            skipped: false,
            eventsProcessed: events.count,
            cursorAdvancedMs: advancedCursor
        )
    }
}
