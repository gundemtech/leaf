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
    private let database: Database
    private let provider: any GitHubAPIProvider
    private let refresher: GitHubTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

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

        // 5. Map + atomic write.
        let events = batch.events.map { Self.makeEvent(snapshot: $0) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
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
            try database.writeEventsAndOffset(events, offset: offset)
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
