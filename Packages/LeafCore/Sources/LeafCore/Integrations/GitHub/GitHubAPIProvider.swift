//
//  GitHubAPIProvider.swift
//  LeafCore
//
//  Phase 4.3 — protocol для REST polling GitHub events feed.
//  Prod implementation (`GET /users/<login>/events?per_page=100`, parsing
//  PushEvent/PullRequestEvent/IssuesEvent/PullRequestReviewEvent payloads,
//  ADR-010 enforcement) живёт в LeafCorePrivate (moat). Public Stub возвращает
//  empty result — CI builds компилируются, runtime no-op.
//

import Foundation

public protocol GitHubAPIProvider: Sendable {
    /// `since` — epoch ms cursor (newest processed `created_at` от прошлого tick'а).
    /// `nil` = bootstrap, provider решает window сам (default: первая страница events feed,
    /// REST events ограничен ~90 днями).
    /// Provider фильтрует client-side: `event.createdAtMs > since`. Возвращает batch + cursor;
    /// throws на network/parsing failures. `login` — viewer login из `GET /user`,
    /// used для path `/users/<login>/events`.
    func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch

    /// Phase 4.7.B-1 — `GET /notifications?all=false&participating=false&per_page=50`.
    /// State pulse — что в моём inbox прямо сейчас. Returns total unread count + breakdown
    /// by `reason`. Reasons we track: "review_requested", "mention", "ci_activity", "comment",
    /// "team_mention", "author", "subscribed", "manual", "state_change". Bucket "other" для unknown.
    /// Body / subject text НЕ extract'им (ADR-010). Provider возвращает `.empty(nowMs:)` на
    /// non-200 / parse failure — graceful degradation, не блокирует events tick.
    func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary

    /// Phase 4.7.B-2 — `GET /search/issues?q=review-requested:@me+is:open+is:pr&per_page=50`.
    /// State pulse — сколько PRs ждут моего review прямо сейчас + top repo
    /// (most pending PRs). Body / title text НЕ extract'им (ADR-010) — только count
    /// + repo identifier (parsed из `repository_url` каждого item'а). Provider возвращает
    /// `.empty(nowMs:)` на non-200 / parse failure — graceful degradation.
    /// `login` сейчас не used (`@me` query token), но reserved для future per-org filter.
    func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary

    /// Phase 4.7.B-2 — `GET /search/issues?q=author:@me+is:open+is:pr&per_page=50`.
    /// State pulse — сколько моих PRs открыто across orgs. ADR-010: ни title ни body
    /// не читаем; берём только count. Provider возвращает `.empty(nowMs:)` на failure.
    func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary
}

/// Результат одного REST fetch'а. `cursorMs` — `max(createdAt)` across `events`
/// (REST events feed DESC by `created_at` → `events.first?.createdAtMs`),
/// или `nil` если batch пуст (cursor не двигается, retry next tick).
/// Mirroring `LinearIssueBatch` — schema-aligned timestamp cursor вместо eventID-as-cursor
/// (collector_offsets.last_modified_ms — strictly INTEGER).
public struct GitHubEventBatch: Sendable, Hashable {
    public let events: [GitHubEventSnapshot]
    public let cursorMs: Int64?

    public init(events: [GitHubEventSnapshot], cursorMs: Int64?) {
        self.events = events
        self.cursorMs = cursorMs
    }

    public static let empty = GitHubEventBatch(events: [], cursorMs: nil)
}

/// Один event в batch'е — public-safe metadata (whitepaper Section 6 Action signal).
/// Bodies / comment text / file diffs НЕ хранятся (ADR-010 won't-list); commit message —
/// только первая строка (subject), всё после `\n` отбрасывается на уровне provider'а.
public struct GitHubEventSnapshot: Sendable, Hashable {
    /// REST events `id` — used for parser-side dedup внутри одного fetch'а
    /// (cursor-by-timestamp imperfect для events с identical `created_at`).
    public let eventID: String
    /// Канонический kind после маппинга raw GitHub `type` + `payload.action`.
    /// Phase 4.6 baseline: "commit_pushed" | "pr_opened" | "pr_merged" | "pr_closed"
    /// | "issue_opened" | "issue_closed" | "review_submitted".
    /// Phase 4.7.A additions: "pr_review_comment_authored" | "issue_comment_authored"
    /// | "release_published" | "branch_created" | "branch_deleted" | "tag_created"
    /// | "discussion_authored" | "discussion_comment_authored".
    public let eventKind: String
    /// "owner/name" — self-authored repo identifier, public-safe.
    public let repoFullName: String
    /// Commit subject (только первая строка) для commit_pushed; PR title; issue title.
    public let title: String
    /// PR/issue/discussion number; `nil` для commit_pushed / review_submitted без issue context.
    public let number: Int?
    /// Commit SHA (short or full) для PushEvent; `nil` для не-push.
    public let sha: String?
    /// Branch ref (e.g. "main") для PushEvent / branch_created / branch_deleted.
    public let branch: String?
    /// Epoch ms — становится cursor для следующего polling tick'а (max `createdAtMs`
    /// идёт в `GitHubEventBatch.cursorMs` → `collector_offsets.last_modified_ms`).
    public let createdAtMs: Int64
    /// Phase 4.6.A.1 — для `pr_merged`: `closed_at - created_at` в секундах. `nil` для
    /// других eventKind'ов или если timestamps отсутствуют в payload (clock skew clamped к 0).
    public let cycleSeconds: Int?
    /// Phase 4.6.A.1 — для `review_submitted`: `review.submitted_at - pull_request.created_at`
    /// в секундах. `nil` для других eventKind'ов или missing timestamps.
    public let reviewDelaySeconds: Int?
    /// Phase 4.7.A — extension slot для new event_kinds с per-kind payload fields
    /// (`action`, `tag_name`, `category`, `comment_id`, `is_pull_request`,
    /// `linked_linear_id`). `nil` или empty dict — не emit'им keys в payload (отличает
    /// "не знаем" от пустого значения). Existing baseline event_kinds оставляют nil.
    public let metadata: [String: String]?

    public init(
        eventID: String,
        eventKind: String,
        repoFullName: String,
        title: String,
        number: Int?,
        sha: String?,
        branch: String?,
        createdAtMs: Int64,
        cycleSeconds: Int? = nil,
        reviewDelaySeconds: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        self.eventID = eventID
        self.eventKind = eventKind
        self.repoFullName = repoFullName
        self.title = title
        self.number = number
        self.sha = sha
        self.branch = branch
        self.createdAtMs = createdAtMs
        self.cycleSeconds = cycleSeconds
        self.reviewDelaySeconds = reviewDelaySeconds
        self.metadata = metadata
    }
}

/// Phase 4.7.B-1 — summary одного `/notifications` fetch'а. State snapshot (не events log):
/// `totalUnread` = что лежит в inbox прямо сейчас, `byReason` — breakdown.
/// Включается в events feed как single `github_notifications_pulse` event с
/// `signal_type=.context` (не `.action` — это state pulse, не user action).
public struct GitHubNotificationsSummary: Sendable, Hashable {
    /// Сумма unread notifications across all reasons. `byReason.values.sum()`,
    /// но stored independently на случай если parsing бакета `other` отстаёт от raw count.
    public let totalUnread: Int
    /// Reason → count. Только non-zero buckets (parser не emit'ит ключ если 0).
    public let byReason: [String: Int]
    /// `now` от Agent'а в момент fetch'а — used как `observed_at_ms` в payload event'а.
    public let observedAtMs: Int64

    public init(totalUnread: Int, byReason: [String: Int], observedAtMs: Int64) {
        self.totalUnread = totalUnread
        self.byReason = byReason
        self.observedAtMs = observedAtMs
    }

    /// Used при non-200 / parse failure / collector graceful degradation.
    /// `observedAtMs` всё равно populated — потому что pulse event с total_unread=0
    /// семантически валиден ("inbox empty в момент N").
    public static func empty(nowMs: Int64) -> GitHubNotificationsSummary {
        GitHubNotificationsSummary(totalUnread: 0, byReason: [:], observedAtMs: nowMs)
    }
}

/// Phase 4.7.B-2 — summary `/search/issues?q=review-requested:@me+is:open+is:pr`.
/// State snapshot: количество PRs ждущих моего review + top repo (most pending PRs)
/// для self-UI. ADR-010: ни title, ни body items не читаем — только `repository_url`.
/// Эмитится как `pr_awaiting_review_count` event с `signal_type=.context`.
public struct GitHubReviewQueueSummary: Sendable, Hashable {
    /// Сумма PRs awaiting my review (search.issues `total_count` или len(items[])).
    public let count: Int
    /// "owner/repo" с most-pending PRs. `nil` если `count == 0`.
    /// На равенстве — берём первый встреченный (search.issues порядок by best-match).
    public let topRepo: String?
    /// `now` от Agent'а в момент fetch'а. Used как `observed_at_ms` в payload.
    public let observedAtMs: Int64

    public init(count: Int, topRepo: String?, observedAtMs: Int64) {
        self.count = count
        self.topRepo = topRepo
        self.observedAtMs = observedAtMs
    }

    /// Used при non-200 / parse failure / graceful degradation. `count=0` +
    /// `topRepo=nil` — семантически валиден ("review queue empty в момент N").
    public static func empty(nowMs: Int64) -> GitHubReviewQueueSummary {
        GitHubReviewQueueSummary(count: 0, topRepo: nil, observedAtMs: nowMs)
    }
}

/// Phase 4.7.B-2 — summary `/search/issues?q=author:@me+is:open+is:pr`.
/// State snapshot: количество моих open PRs across orgs. ADR-010: ни title, ни body
/// не читаем — только count. Эмитится как `my_open_pr_count` event, `signal_type=.context`.
public struct GitHubMyOpenPRsSummary: Sendable, Hashable {
    /// Сумма моих open PRs.
    public let count: Int
    /// `now` от Agent'а в момент fetch'а. Used как `observed_at_ms` в payload.
    public let observedAtMs: Int64

    public init(count: Int, observedAtMs: Int64) {
        self.count = count
        self.observedAtMs = observedAtMs
    }

    /// Used при non-200 / parse failure / graceful degradation.
    public static func empty(nowMs: Int64) -> GitHubMyOpenPRsSummary {
        GitHubMyOpenPRsSummary(count: 0, observedAtMs: nowMs)
    }
}

/// Stub для CI / dev-без-moat сборок. Никогда не делает HTTP call, возвращает
/// `.empty` — GitHubCollector tick проходит no-op.
public struct StubGitHubAPIProvider: GitHubAPIProvider {
    public init() {}
    public func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
        .empty
    }
    public func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
    public func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
    public func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
