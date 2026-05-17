//
//  LinearCollector.swift
//  LeafCore
//
//  Phase 4.2 — Linear polling collector. Раз в `intervalSec`:
//  1. Читает `integrations` row (provider=.linear). Если row нет → tick skipped.
//  2. `refresher.refreshIfNeeded(now:)` — обновляет access token если истекает.
//     На `.refreshDenied` (invalid_grant) refresher уже сам делает deleteIntegration
//     + UserDefaults flag + DistributedNotification → UI surface'ит "Reconnect needed".
//  3. `provider.fetchIssues(accessToken:since:)` — GraphQL POST. `since` =
//     stored `lastModifiedMs` cursor; bootstrap → `nil` → provider использует
//     backfill window.
//  4. Map результат в `[RawEvent]` с `signal_type=.action`, `payload.source=linear`.
//  5. Atomic write через `writeEventsAndOffset(events:offset:)` — events + cursor
//     в одной транзакции. Cursor = `batch.cursorMs` (newest updatedAt).
//
//  Phase 2.3.C.3 split — `performTick` lives in `LinearCollector+Tick.swift`,
//  static event builders + presence-state composer in
//  `LinearCollector+EventBuilders.swift`.
//

import Foundation
import os

public actor LinearCollector {
    /// Phase 4.5 — UserDefaults flag для одноразового wipe старых
    /// (контаминированных teammate-noise) Linear events при первом start
    /// после upgrade. Idempotent: после успешной миграции flag остаётся true,
    /// last-state-wins при повторном start.
    public static let attributionV2MigrationFlagKey = "linear.attribution_v2_migrated"

    let database: Database
    let provider: any LinearGraphQLProvider
    let refresher: LinearTokenRefresher
    let intervalSec: TimeInterval
    let backfillWindowDays: Int
    let logger: Logger
    private let restartTriggerName: String
    /// Phase 4.5 — UserDefaults suite name под Migration flag. Sendable-friendly
    /// (String) — UserDefaults instance строится lazy внутри actor'а. Тесты
    /// передают unique suite ("leaf-test-<UUID>") чтобы изолировать flag от
    /// shared `tech.gundem.leaf` (где живёт production state).
    private let userDefaultsSuiteName: String?

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    public init(
        database: Database,
        provider: any LinearGraphQLProvider,
        refresher: LinearTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        restartTriggerName: String = LinearOAuthEndpoints.integrationChangedNotificationName,
        logger: Logger,
        userDefaultsSuiteName: String? = "tech.gundem.leaf"
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.restartTriggerName = restartTriggerName
        self.logger = logger
        self.userDefaultsSuiteName = userDefaultsSuiteName
    }

    private var userDefaults: UserDefaults {
        if let name = userDefaultsSuiteName, let suite = UserDefaults(suiteName: name) {
            return suite
        }
        return .standard
    }

    public func start() {
        guard loopTask == nil else { return }
        runOneTimeMigration()
        let name = NSNotification.Name(restartTriggerName)
        notifyToken = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.kickTick() }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info(
            "LinearCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)"
        )
    }

    /// Phase 4.5 — одноразовый wipe Linear events + cursor для перехода на
    /// per-action attribution. Атомарно (transaction в `purgeLinearAttributionV2`),
    /// идемпотентно (UserDefaults flag), не bubble'ит ошибки выше — collector
    /// должен start'ануть даже если миграция fail'нула (например DB locked
    /// другим процессом), retry на следующий start.
    private func runOneTimeMigration() {
        guard !userDefaults.bool(forKey: Self.attributionV2MigrationFlagKey) else { return }
        do {
            let result = try database.purgeLinearAttributionV2()
            userDefaults.set(true, forKey: Self.attributionV2MigrationFlagKey)
            logger.info(
                "Linear attribution_v2 migration: events=\(result.eventsDeleted, privacy: .public) wiped, offsets=\(result.offsetsDeleted, privacy: .public) reset"
            )
        } catch {
            logger.error(
                "Linear attribution_v2 migration failed: \(String(describing: error), privacy: .public) — will retry next start"
            )
        }
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        if let t = notifyToken {
            DistributedNotificationCenter.default().removeObserver(t)
            notifyToken = nil
        }
        logger.info("LinearCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let issuesProcessed: Int
        public let cursorAdvancedMs: Int64?
        /// Phase 4.7.A — linear_comment_authored events emitted в этом tick'е (один per issue с count > 0).
        public let commentEventsEmitted: Int
        /// Phase 4.7.B (B-7) — linear_cycle_progress events emitted в этом tick'е
        /// (один per team с активным cycle'ом). 0 если ни одна команда не in-cycle.
        public let cycleEventsEmitted: Int

        public init(
            skipped: Bool,
            issuesProcessed: Int,
            cursorAdvancedMs: Int64?,
            commentEventsEmitted: Int = 0,
            cycleEventsEmitted: Int = 0
        ) {
            self.skipped = skipped
            self.issuesProcessed = issuesProcessed
            self.cursorAdvancedMs = cursorAdvancedMs
            self.commentEventsEmitted = commentEventsEmitted
            self.cycleEventsEmitted = cycleEventsEmitted
        }
    }

    private func kickTick() async {
        await performTick()
    }

    private func runLoop() async {
        // Initial small delay (cheap startup).
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
