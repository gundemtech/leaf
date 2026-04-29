//
//  SlackCollector.swift
//  LeafCore
//
//  Phase 4.4 B6 — Slack REST polling collector. Mirror'ит Linear/GitHub
//  collector pattern с двумя Slack-специфичными deviations:
//   1. Per-tick result agreggate'ит messages per channel (1 RawEvent per
//      (channel, count, tick) — D6) и detect'ит huddle transition сравнением
//      с last DB event (`Database.readLatestSlackHuddleEvent`).
//   2. workspaceID хранится в формате "<team_id>:<user_id>" (см. SlackOAuthService
//      persistence shape, B2). Collector сплитит на user_id для logging /
//      defensive guard, но `from:me` query alias делает userID не-required
//      для search query — он сохранён в provider signature на случай
//      fallback path.
//
//  Atomic write: events + offset идут одной транзакцией через
//  `writeEventsAndOffset`. Если batch пустой и no transition — cursor
//  не двигается (retry next tick на тех же `since`), идентично Linear/GitHub.
//

import Foundation
import os

public actor SlackCollector {
    private let database: Database
    private let provider: any SlackAPIProvider
    private let refresher: SlackTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    public init(
        database: Database,
        provider: any SlackAPIProvider,
        refresher: SlackTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        restartTriggerName: String = SlackOAuthEndpoints.integrationChangedNotificationName,
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
        logger.info("SlackCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        if let t = notifyToken {
            DistributedNotificationCenter.default().removeObserver(t)
            notifyToken = nil
        }
        logger.info("SlackCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let messageEventsEmitted: Int
        public let huddleTransitionEmitted: Bool
        public let cursorAdvancedMs: Int64?
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .slack)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → refresher уже сделал
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch SlackTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — Slack disconnected: \(msg, privacy: .public)")
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }

        // 3. Parse userID из workspaceID "<team>:<user>" — формат гарантирован
        // SlackOAuthService persistence (B2). Defensive: malformed → skip.
        let parts = refreshed.workspaceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            logger.error("malformed workspaceID '\(refreshed.workspaceID, privacy: .public)' — expected '<team>:<user>'")
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }
        let userID = String(parts[1])

        // 4. Read cursor.
        let sourceID = "slack:\(refreshed.workspaceID)"
        let stored: CollectorOffset?
        do {
            stored = try database.readOffset(
                collectorID: CollectorID.slackPolling,
                sourceID: sourceID
            )
        } catch {
            logger.error("readOffset failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }
        let since: Int64? = stored?.lastModifiedMs

        // 5. Fetch tick result (huddle state + per-channel message counts).
        let tick: SlackTickResult
        do {
            tick = try await provider.fetchTick(
                accessToken: refreshed.accessToken,
                userID: userID,
                since: since,
                now: now
            )
        } catch {
            logger.error("fetchTick failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }

        // 6. Compose events.
        // 6a. Message events — один Action RawEvent per (channel, count > 0).
        let messageEvents: [RawEvent] = tick.channelMessageCounts
            .filter { $0.count > 0 }
            .map {
                Self.makeMessageEvent(
                    channel: $0,
                    periodStartMs: tick.periodStartMs,
                    periodEndMs: tick.periodEndMs
                )
            }

        // 6b. Huddle transition event — emit только если state различается с
        // последним DB-зафиксированным huddle event'ом. .unknown → skip
        // (provider не смог fetch). Первый ever event (DB пуст) → emit
        // baseline transition.
        var huddleEvent: RawEvent?
        if tick.huddle != .unknown {
            let prevState: SlackHuddleState?
            do {
                let prev = try database.readLatestSlackHuddleEvent()
                prevState = prev.map { SlackHuddleState(slackAPIString: $0.state) }
            } catch {
                logger.error("readLatestSlackHuddleEvent failed: \(String(describing: error), privacy: .public)")
                prevState = nil
            }
            if prevState != tick.huddle {
                huddleEvent = Self.makeHuddleEvent(state: tick.huddle, now: now)
            }
        }

        let allEvents: [RawEvent] = messageEvents + (huddleEvent.map { [$0] } ?? [])

        // 7. Atomic write events + cursor.
        // Cursor двигается только когда provider дал nonempty cursorMs (т.е.
        // были messages в batch'е). Empty batch + no transition → cursor
        // остаётся (retry next tick), как Linear/GitHub.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let advancedCursor = tick.cursorMs ?? since
        let offset = CollectorOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: advancedCursor ?? nowMs,
            updatedMs: nowMs
        )
        do {
            try database.writeEventsAndOffset(allEvents, offset: offset)
        } catch {
            logger.error("persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(
                skipped: false,
                messageEventsEmitted: 0,
                huddleTransitionEmitted: false,
                cursorAdvancedMs: nil
            )
        }
        if !allEvents.isEmpty {
            logger.info("tick wrote \(messageEvents.count, privacy: .public) message events + \(huddleEvent != nil ? 1 : 0, privacy: .public) huddle, cursor=\(offset.lastModifiedMs, privacy: .public)")
        }
        return TickResult(
            skipped: false,
            messageEventsEmitted: messageEvents.count,
            huddleTransitionEmitted: huddleEvent != nil,
            cursorAdvancedMs: advancedCursor
        )
    }

    private static func makeMessageEvent(
        channel: SlackChannelMessageCount,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) -> RawEvent {
        // Aggregate event — timestamp = period boundary, не индивидуальное
        // message ts (count > 1 не имеет single moment).
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "message_authored_aggregate",
                "channel_name": channel.channelName,
                "count": String(channel.count),
                "period_start_ms": String(periodStartMs),
                "period_end_ms": String(periodEndMs)
            ]
        )
    }

    private static func makeHuddleEvent(state: SlackHuddleState, now: Date) -> RawEvent {
        // Transition timestamp = `now` (а не moment самого huddle start) —
        // мы не знаем точный момент между ticks; ±5min неточность приемлема в MVP.
        RawEvent(
            timestamp: now,
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "huddle_state_change",
                "state": state.rawValue
            ]
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
