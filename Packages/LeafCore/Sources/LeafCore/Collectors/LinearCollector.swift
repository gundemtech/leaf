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

import Foundation
import os

public actor LinearCollector {
    /// Phase 4.5 — UserDefaults flag для одноразового wipe старых
    /// (контаминированных teammate-noise) Linear events при первом start
    /// после upgrade. Idempotent: после успешной миграции flag остаётся true,
    /// last-state-wins при повторном start.
    public static let attributionV2MigrationFlagKey = "linear.attribution_v2_migrated"

    private let database: Database
    private let provider: any LinearGraphQLProvider
    private let refresher: LinearTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
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
        logger.info("LinearCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)")
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
            logger.info("Linear attribution_v2 migration: events=\(result.eventsDeleted, privacy: .public) wiped, offsets=\(result.offsetsDeleted, privacy: .public) reset")
        } catch {
            logger.error("Linear attribution_v2 migration failed: \(String(describing: error), privacy: .public) — will retry next start")
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
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .linear)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → refresher уже сделал
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch LinearTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — Linear disconnected: \(msg, privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 3. Read cursor.
        let sourceID = "linear:\(refreshed.workspaceID)"
        let stored: CollectorOffset?
        do {
            stored = try database.readOffset(
                collectorID: CollectorID.linearPolling,
                sourceID: sourceID
            )
        } catch {
            logger.error("readOffset failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        let since: Int64? = stored?.lastModifiedMs

        // 4. Fetch.
        let batch: LinearIssueBatch
        do {
            batch = try await provider.fetchIssues(
                accessToken: refreshed.accessToken,
                since: since
            )
        } catch {
            logger.error("fetchIssues failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 5. Map + atomic write.
        let events = batch.issues.map { Self.makeEvent(issue: $0) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Если batch пуст — cursor НЕ двигается (retry next tick на тех же since).
        // Если batch не пуст — cursor = batch.cursorMs (max updatedAt).
        let advancedCursor = batch.cursorMs ?? since
        let offset = CollectorOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: advancedCursor ?? nowMs,
            updatedMs: nowMs
        )
        do {
            try database.writeEventsAndOffset(events, offset: offset)
        } catch {
            logger.error("persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        if !events.isEmpty {
            logger.info("tick wrote \(events.count, privacy: .public) issues, cursor=\(offset.lastModifiedMs, privacy: .public)")
        }
        return TickResult(
            skipped: false,
            issuesProcessed: events.count,
            cursorAdvancedMs: advancedCursor
        )
    }

    private static func makeEvent(issue: LinearIssueSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "issue_updated",
            "issue_key": issue.issueKey,
            "title": issue.title,
            "status": issue.status,
            "project": issue.project,
            "team_key": issue.teamKey
        ]
        // Phase 4.6.A.2 — completion duration. Только non-nil → ключ присутствует;
        // отсутствие ключа в payload отличает "не знаем" от "0 секунд" (instant
        // close). SQL aggregator фильтрует `IS NOT NULL`, а не `> 0`, чтобы
        // legitimate zero samples учитывались.
        if let secs = issue.completionSeconds {
            payload["completion_seconds"] = String(secs)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(issue.updatedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
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
