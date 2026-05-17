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
//  Phase 2.3.C.3 split — `performTick` lives in `GitHubCollector+Tick.swift`,
//  static event builders in `GitHubCollector+EventBuilders.swift`.
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
    static let activeReposCap = 10
    /// Phase 4.7.B-3 — sliding window для derive активных repos из `events` table.
    /// 7 дней — достаточно чтобы поймать недельный rhythm проекта без false-positive
    /// от старого ad-hoc activity. Конфигурабельно (constant) если потребуется tuning.
    static let activeReposLookbackDays = 7

    let database: Database
    let provider: any GitHubAPIProvider
    let refresher: GitHubTokenRefresher
    let intervalSec: TimeInterval
    let backfillWindowDays: Int
    let logger: Logger
    private let restartTriggerName: String

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Phase 4.7.B-5 — in-memory cooldown gate для daily contributions GraphQL.
    /// `"yyyy-MM-dd"` UTC; refetch fires только когда day rolls over. Reset на
    /// app restart — допустимо: at-most one redundant fetch per launch (REST
    /// `/graphql` cost ≈ negligible под 5000pts/hr secondary limit).
    var lastContributionsFetchDay: String?
    /// Phase 4.7.B-5 — cached value across ticks. Updated только когда fresh
    /// calendar fetched в этом tick'е (cooldown gate didn't fire). Sticky:
    /// если today's day rolls over но fetch упал, prev value остаётся в
    /// `presence_state` — non-zero false-positive менее плох, чем silent drop.
    var lastContributionsToday: Int = 0

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
        logger.info(
            "GitHubCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)"
        )
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
