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
//  Phase 2.3.C.3 split — `performTick` lives in `SlackCollector+Tick.swift`,
//  composite presence-state composer + static event builders in
//  `SlackCollector+EventBuilders.swift`.
//

import Foundation
import os

public actor SlackCollector {
    let database: Database
    let provider: any SlackAPIProvider
    let refresher: SlackTokenRefresher
    let intervalSec: TimeInterval
    let backfillWindowDays: Int
    let logger: Logger
    private let restartTriggerName: String
    /// Phase Track-1 D1 — max threads fan-out'ed per tick. Defaults to Int.max
    /// (no cap) so existing tests and stub paths are unaffected. Production wiring
    /// in LeafAgent injects SlackBudgets.maxThreadsPerTick (moat constant).
    let maxThreadsPerTick: Int

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Phase 4.7.A — last emitted custom-status emoji. In-memory, reset на restart.
    /// `nil` = ещё не наблюдали в этом процессе (first-tick всегда emit). Acceptable
    /// double-emit на crash-restart — emoji rarely changes (юзер выставил намеренно),
    /// дубликаты dedupable downstream через одинаковый `transition_at`.
    private(set) var lastEmittedStatusEmoji: String?

    public init(
        database: Database,
        provider: any SlackAPIProvider,
        refresher: SlackTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        maxThreadsPerTick: Int = Int.max,
        restartTriggerName: String = SlackOAuthEndpoints.integrationChangedNotificationName,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.maxThreadsPerTick = maxThreadsPerTick
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
            "SlackCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)"
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
        logger.info("SlackCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let messageEventsEmitted: Int
        public let huddleTransitionEmitted: Bool
        public let cursorAdvancedMs: Int64?
        /// Phase 4.7.A — кол-во slack_thread_reply_aggregate events emitted в этом tick'е.
        public let threadReplyEventsEmitted: Int
        /// Phase 4.7.A — true если в этом tick'е emit'ился slack_status_change.
        public let statusChangeEmitted: Bool
        /// Phase 4.7.B-9 — true если в этом tick'е emit'ился slack_presence_state pulse.
        /// Should be true каждый non-skipped tick (always-emit semantics).
        public let presenceStateEmitted: Bool
        /// Phase 4.7.B-10 — true если в этом tick'е emit'ился slack_dnd_state pulse.
        /// Should be true каждый non-skipped tick (always-emit semantics).
        public let dndStateEmitted: Bool
        /// Phase 4.7.B-11 — кол-во slack_mention_received_aggregate events emitted
        /// в этом tick'е (один event per channel-bucket, count=mentions per period).
        /// 0 = no mentions / graceful degrade на provider-throw / ratelimit.
        public let mentionEventsEmitted: Int
        /// Phase 4.7.B-12 — true если в этом tick'е emit'ился
        /// `slack_file_uploaded_aggregate`. Should be true каждый non-skipped tick
        /// (always-emit semantics — substrate continuity, mirror к presence/dnd).
        public let fileUploadEventEmitted: Bool

        public init(
            skipped: Bool,
            messageEventsEmitted: Int,
            huddleTransitionEmitted: Bool,
            cursorAdvancedMs: Int64?,
            threadReplyEventsEmitted: Int = 0,
            statusChangeEmitted: Bool = false,
            presenceStateEmitted: Bool = false,
            dndStateEmitted: Bool = false,
            mentionEventsEmitted: Int = 0,
            fileUploadEventEmitted: Bool = false
        ) {
            self.skipped = skipped
            self.messageEventsEmitted = messageEventsEmitted
            self.huddleTransitionEmitted = huddleTransitionEmitted
            self.cursorAdvancedMs = cursorAdvancedMs
            self.threadReplyEventsEmitted = threadReplyEventsEmitted
            self.statusChangeEmitted = statusChangeEmitted
            self.presenceStateEmitted = presenceStateEmitted
            self.dndStateEmitted = dndStateEmitted
            self.mentionEventsEmitted = mentionEventsEmitted
            self.fileUploadEventEmitted = fileUploadEventEmitted
        }
    }

    /// Actor-internal mutator for `lastEmittedStatusEmoji`. Extensions cannot
    /// write `private(set)` actor state directly, so the +Tick extension uses
    /// this thin setter.
    func setLastEmittedStatusEmoji(_ value: String) {
        lastEmittedStatusEmoji = value
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
