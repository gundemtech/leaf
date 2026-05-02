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

    /// Phase 4.7.A — last emitted custom-status emoji. In-memory, reset на restart.
    /// `nil` = ещё не наблюдали в этом процессе (first-tick всегда emit). Acceptable
    /// double-emit на crash-restart — emoji rarely changes (юзер выставил намеренно),
    /// дубликаты dedupable downstream через одинаковый `transition_at`.
    private var lastEmittedStatusEmoji: String?

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

        // 5a. Phase 4.7.B-9 — presence pulse. Independent of fetchTick — observability
        // continuity discipline: even на network throw мы emit'им pulse с state="unknown"
        // чтобы downstream видел "observed but undeterminable" без gap'ов между tick'ами.
        // Provider impl сам делает graceful degrade на 401/429/parse, но network throw
        // bubble'ит наверх — wrap'им здесь.
        let presenceState: SlackPresenceState
        do {
            presenceState = try await provider.fetchPresence(
                accessToken: refreshed.accessToken,
                userID: userID
            )
        } catch {
            logger.error("fetchPresence failed: \(String(describing: error), privacy: .public)")
            presenceState = .unknown
        }

        // 5b. Phase 4.7.B-10 — DND pulse. Same observability discipline что и
        // fetchPresence: graceful `.empty` на network throw чтобы не блокировать
        // tick. Provider impl сам degrade'ит на 401/429/parse, но network throw
        // bubble'ит — wrap'им здесь.
        let dndState: SlackDNDState
        do {
            dndState = try await provider.fetchDND(
                accessToken: refreshed.accessToken,
                userID: userID
            )
        } catch {
            logger.error("fetchDND failed: \(String(describing: error), privacy: .public)")
            dndState = .empty
        }

        // 5c. Phase 4.7.B-11 — mentions received aggregate. Per-channel count'ы
        // сообщений где меня mention'нули за период `[since, now]` (bootstrap
        // window — provider-side, по умолчанию 7 дней). Graceful: throw → []
        // (no events emitted этим mechanism'ом). Period semantics: `since` =
        // tick cursor (либо 0 на bootstrap path — provider обработает).
        // Mentions — это NOT message activity (от меня); это received-from-others.
        // Cursor для mention search не двигаем — окно перекрывается tick-to-tick
        // и нам важен `периодический snapshot`, а не точный delta dedup.
        let mentionCounts: [SlackMentionChannelCount]
        do {
            mentionCounts = try await provider.fetchMentionsReceived(
                accessToken: refreshed.accessToken,
                userID: userID,
                since: since ?? 0
            )
        } catch {
            logger.error("fetchMentionsReceived failed: \(String(describing: error), privacy: .public)")
            mentionCounts = []
        }

        // 5d. Phase 4.7.B-12 — files uploaded aggregate. Single aggregate per
        // tick (count + mime-type bucket distribution, NOT per-file timeline).
        // Always emit (mirror к presence/dnd substrate continuity): graceful
        // network throw → `.empty(...)` с count=0, типs пустой. Provider-side
        // 401/429/parse тоже degrade'ят в `.empty(...)`. ADR-010: filenames /
        // previews / permalinks отбрасываются на provider-side parsing'е.
        let nowEpochMsForFiles = Int64(now.timeIntervalSince1970 * 1000)
        let filesSummary: SlackFileUploadSummary
        do {
            filesSummary = try await provider.fetchFilesUploaded(
                accessToken: refreshed.accessToken,
                userID: userID,
                since: since ?? 0
            )
        } catch {
            logger.error("fetchFilesUploaded failed: \(String(describing: error), privacy: .public)")
            filesSummary = .empty(periodStartMs: since ?? 0, periodEndMs: nowEpochMsForFiles)
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

        // 6a'. Phase 4.7.A — thread reply aggregate events. Subset of `count`
        // (replies are still messages). Emit'ится отдельным event_kind рядом
        // с `message_authored_aggregate` чтобы downstream insights могли
        // distinguish "initiation vs reply" без re-parsing payload.
        let threadReplyEvents: [RawEvent] = tick.channelMessageCounts
            .filter { $0.threadReplyCount > 0 }
            .map {
                Self.makeThreadReplyEvent(
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

        // 6c. Phase 4.7.A — slack_status_change event. Compare текущий emoji
        // против last-emitted (in-memory). Different → emit. Idle ticks (тот же
        // emoji) → no emit. First-ever observation per process always emits
        // (lastEmittedStatusEmoji=nil), это acceptable double-emit на restart.
        var statusChangeEvent: RawEvent?
        if tick.statusEmoji != lastEmittedStatusEmoji {
            statusChangeEvent = Self.makeStatusChangeEvent(
                emoji: tick.statusEmoji,
                expirationTs: tick.statusExpirationTs,
                now: now
            )
            lastEmittedStatusEmoji = tick.statusEmoji
        }

        // 6d. Phase 4.7.B-9 — slack_presence_state pulse. ВСЕГДА emit (per-tick
        // pulse, mirror к github_notifications_pulse). `nowMs` определяется ниже
        // в шаге 7 для cursor — компьютим раньше чтобы передать в event.
        let nowMsForPresence = Int64(now.timeIntervalSince1970 * 1000)
        let presenceEvent = Self.makePresenceStateEvent(
            state: presenceState,
            nowMs: nowMsForPresence
        )

        // 6e. Phase 4.7.B-10 — slack_dnd_state pulse. ВСЕГДА emit (per-tick),
        // тот же `nowMs` что и presence (один observation timestamp на tick).
        let dndEvent = Self.makeDNDStateEvent(
            state: dndState,
            nowMs: nowMsForPresence
        )

        // 6f. Phase 4.7.B-11 — mention_received_aggregate events. Один event
        // per channel-bucket с count > 0 (provider гарантирует count > 0 в
        // groups, но belt-and-suspenders filter здесь). count=0 буффер не
        // создаём — provider drop'ает channels без matches до return.
        let mentionEvents: [RawEvent] = mentionCounts
            .filter { $0.count > 0 }
            .map { Self.makeMentionReceivedAggregateEvent(channelCount: $0, nowMs: nowMsForPresence) }

        // 6g. Phase 4.7.B-12 — slack_file_uploaded_aggregate. Single event per
        // tick (NOT per-file). Always emit — mirror к presence/dnd: на zero count
        // тоже emit (substrate continuity, downstream видит "наблюдали, файлов
        // не было" vs "не наблюдали"). Flatten typesSummary в top-level keys
        // (image_count / code_count / doc_count / other_count) для query-friendly
        // SQL access.
        let fileUploadEvent = Self.makeFileUploadedAggregateEvent(
            summary: filesSummary,
            nowMs: nowMsForPresence
        )

        // Compose tick events. Split в локальные slices чтобы Swift type-checker
        // не задыхался на длинной chained-`+` expression.
        var allEvents: [RawEvent] = []
        allEvents.append(contentsOf: messageEvents)
        allEvents.append(contentsOf: threadReplyEvents)
        if let huddleEvent { allEvents.append(huddleEvent) }
        if let statusChangeEvent { allEvents.append(statusChangeEvent) }
        allEvents.append(presenceEvent)
        allEvents.append(dndEvent)
        allEvents.append(contentsOf: mentionEvents)
        allEvents.append(fileUploadEvent)

        // 7. Build presence_state.slack composite snapshot.
        // ADR-010 boundary: только counts / public-safe identifiers / enums /
        // emoji literal. Никаких message text / file names / mention bodies
        // не попадает (provider их не парсит, build dict здесь — defensive,
        // мы строим его из уже-redacted snapshot'ов).
        // JSONSerialization-friendly: Int / Bool / String / [String: Any].
        // Optional ts → 0 per plan literal (downstream parser проверяет
        // наличие через > 0 или строковое сравнение с "" для channel'а).
        let slackPresence: [String: Any] = Self.buildSlackPresenceState(
            tick: tick,
            presenceState: presenceState,
            dnd: dndState,
            mentions: mentionCounts,
            files: filesSummary
        )

        // 8. Atomic write events + cursor + presence_state.
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
            try database.writeEventsOffsetAndPresence(
                allEvents,
                offset: offset,
                presence: (.slack, slackPresence, nil),
                nowMs: nowMs
            )
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
            logger.info("tick wrote \(messageEvents.count, privacy: .public) message + \(threadReplyEvents.count, privacy: .public) thread-reply + \(huddleEvent != nil ? 1 : 0, privacy: .public) huddle + \(statusChangeEvent != nil ? 1 : 0, privacy: .public) status + 1 presence + 1 dnd + \(mentionEvents.count, privacy: .public) mentions + 1 file-upload events, cursor=\(offset.lastModifiedMs, privacy: .public)")
        }
        return TickResult(
            skipped: false,
            messageEventsEmitted: messageEvents.count,
            huddleTransitionEmitted: huddleEvent != nil,
            cursorAdvancedMs: advancedCursor,
            threadReplyEventsEmitted: threadReplyEvents.count,
            statusChangeEmitted: statusChangeEvent != nil,
            presenceStateEmitted: true,
            dndStateEmitted: true,
            mentionEventsEmitted: mentionEvents.count,
            fileUploadEventEmitted: true
        )
    }

    /// Phase 4.7.B-13 — composite `presence_state.slack` snapshot. Single point
    /// of truth для Slack-side state visible to команде через Phase 5 broadcast.
    /// Built из tick fetch outputs (already redacted на provider parsing'е).
    ///
    /// Plan-required keys (top-level):
    /// - `native_presence: String` — "active" | "away" | "unknown" (raw value
    ///   `SlackPresenceState`, mirror к API enum).
    /// - `dnd: [String: Any]` — nested dict с 4 keys:
    ///     - `is_active: Bool` — `dnd.dndEnabled`.
    ///     - `snooze_until_ms: Int64` — user-set snooze, 0 если nil (per plan literal).
    ///     - `next_dnd_start_ms: Int64` — scheduled DND start, 0 если nil.
    ///     - `next_dnd_end_ms: Int64` — scheduled DND end, 0 если nil.
    /// - `status_emoji: String` — Slack custom status emoji (Phase 4.7.A), пустая
    ///   строка если не выставлен.
    /// - `status_expiration_ts: Int64` — epoch ms когда status истекает (0 = no expiration).
    /// - `in_huddle: Bool` — `tick.huddle == .inAHuddle` (`.unknown` / `.defaultUnset` → false).
    /// - `huddle_channel: String` — channel name where huddle is active. **Currently
    ///   always `""`** — `SlackHuddleState` enum не несёт channel info на уровне
    ///   API (`profile.huddle_state` отдаёт только enum). Surface зарезервирован
    ///   под потенциальное расширение API parsing'а; downstream readers НЕ должны
    ///   считать "" = "no huddle" — для этого есть `in_huddle`.
    /// - `last_activity_channel: String` — most-recent-message channel за tick window
    ///   (max-count entry в `tick.channelMessageCounts`); `""` если no messages
    ///   authored.
    /// - `mention_count_today: Int` — sum of mention counts по всем channel'ам в
    ///   tick window. Naming "today" — semantic intent (Slack `after:` имеет
    ///   day-resolution); фактически intra-tick aggregate (provider возвращает
    ///   per-channel counts за окно `[since, now]`, мы суммируем). Нulled из DB не
    ///   читаем — каждый tick свежий snapshot.
    /// - `file_count_today: Int` — `filesSummary.count`, naming зеркалирует mention.
    ///
    /// ADR-010 redaction: caller responsibility. `tick.statusEmoji` — pure literal
    /// (provider drop'ает `status_text` body). `last_activity_channel` — public
    /// channel name либо literal "DM" (anonymized в provider'е). Mention/file
    /// counts — numeric only.
    static func buildSlackPresenceState(
        tick: SlackTickResult,
        presenceState: SlackPresenceState,
        dnd: SlackDNDState,
        mentions: [SlackMentionChannelCount],
        files: SlackFileUploadSummary
    ) -> [String: Any] {
        let lastActivityChannel = tick.channelMessageCounts
            .max(by: { $0.count < $1.count })?
            .channelName ?? ""
        let mentionTotal = mentions.map { $0.count }.reduce(0, +)
        let dndDict: [String: Any] = [
            "is_active": dnd.dndEnabled,
            "snooze_until_ms": dnd.snoozeUntilMs ?? 0,
            "next_dnd_start_ms": dnd.nextDNDStartMs ?? 0,
            "next_dnd_end_ms": dnd.nextDNDEndMs ?? 0
        ]
        return [
            "native_presence": presenceState.rawValue,
            "dnd": dndDict,
            "status_emoji": tick.statusEmoji,
            "status_expiration_ts": tick.statusExpirationTs,
            "in_huddle": tick.huddle == .inAHuddle,
            // huddle_channel: surface зарезервирован, current API parser не
            // populates — `SlackHuddleState` enum только indicator, без channel.
            "huddle_channel": "",
            "last_activity_channel": lastActivityChannel,
            "mention_count_today": mentionTotal,
            "file_count_today": files.count
        ]
    }

    private static func makeMessageEvent(
        channel: SlackChannelMessageCount,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) -> RawEvent {
        // Aggregate event — timestamp = period boundary, не индивидуальное
        // message ts (count > 1 не имеет single moment).
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": "message_authored_aggregate",
            "channel_name": channel.channelName,
            "count": String(channel.count),
            "period_start_ms": String(periodStartMs),
            "period_end_ms": String(periodEndMs)
        ]
        // Phase 4.6.A.3 — reactions_count present ↔ "знаем что были реакции".
        // Отсутствие ключа = "0 реакций или старая alpha.6 без 4.6.A.3"
        // (consistent с decision не различать 0 от nil на UI; SQL aggregator
        // фильтрует `IS NOT NULL` чтобы 0-samples не путать с pre-4.6 events).
        if channel.reactionsCount > 0 {
            payload["reactions_count"] = String(channel.reactionsCount)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.A — thread reply aggregate event. Same shape pattern что
    /// `message_authored_aggregate`, distinct event_kind, count=subset.
    private static func makeThreadReplyEvent(
        channel: SlackChannelMessageCount,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_thread_reply_aggregate",
                "channel_name": channel.channelName,
                "count": String(channel.threadReplyCount),
                "period_start_ms": String(periodStartMs),
                "period_end_ms": String(periodEndMs)
            ]
        )
    }

    /// Phase 4.7.A — slack_status_change context event. Emoji = pure literal
    /// (e.g. ":pizza:") или "" если cleared. ADR-010: status_text НЕ читаем
    /// на parsing (provider drop'ает field до payload-finalize).
    private static func makeStatusChangeEvent(
        emoji: String,
        expirationTs: Int64,
        now: Date
    ) -> RawEvent {
        RawEvent(
            timestamp: now,
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_status_change",
                "status_emoji": emoji,
                "status_expiration_ts": String(expirationTs),
                "transition_at": String(Int64(now.timeIntervalSince1970 * 1000))
            ]
        )
    }

    /// Phase 4.7.B-9 — `slack_presence_state` per-tick pulse event. Mirror'ит
    /// `github_notifications_pulse`: эмитится КАЖДЫЙ non-skipped tick (даже на
    /// `.unknown` — observation continuity > shrunk row count). `signal_type=.context`
    /// (state pulse, не user action). Payload — minimal enum + observed ts; ничего
    /// PII (ADR-010), `users.getPresence` response в принципе не содержит body.
    static func makePresenceStateEvent(
        state: SlackPresenceState,
        nowMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_presence_state",
                "state": state.rawValue,
                "observed_at_ms": String(nowMs)
            ]
        )
    }

    /// Phase 4.7.B-10 — `slack_dnd_state` per-tick pulse event. Always-emit
    /// semantics (mirror к `slack_presence_state`): tick → 1 event regardless
    /// of state. `signal_type=.context` (DND — состояние, не user action).
    /// Optional ts payload keys — omit когда nil (consistent с completion_seconds
    /// и прочими existing-conventions; downstream считает отсутствие = "no scheduled" /
    /// "no active snooze"). ADR-010: response не содержит body / PII.
    static func makeDNDStateEvent(
        state: SlackDNDState,
        nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": "slack_dnd_state",
            "dnd_enabled": state.dndEnabled ? "true" : "false",
            "observed_at_ms": String(nowMs)
        ]
        if let snooze = state.snoozeUntilMs {
            payload["snooze_until_ms"] = String(snooze)
        }
        if let nextStart = state.nextDNDStartMs {
            payload["next_dnd_start_ms"] = String(nextStart)
        }
        if let nextEnd = state.nextDNDEndMs {
            payload["next_dnd_end_ms"] = String(nextEnd)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-11 — `slack_mention_received_aggregate` action event. Один
    /// event per channel-bucket (count > 0). Mirror'ит shape `message_authored_aggregate`
    /// (channel + count + period boundaries), но `event_kind` distinct чтобы
    /// downstream insights могли distinguish "что написал я" vs "сколько раз
    /// меня mention'нули". `signal_type=.action` (per plan): mention — это
    /// triggering event для меня (нужно отреагировать), не пассивный state.
    /// ADR-010: текст mention'ящего сообщения и автор mention'а — provider
    /// drop'ает на parsing'е, в payload не попадают.
    static func makeMentionReceivedAggregateEvent(
        channelCount: SlackMentionChannelCount,
        nowMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(channelCount.periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_mention_received_aggregate",
                "channel": channelCount.channelName,
                "count": String(channelCount.count),
                "period_start_ms": String(channelCount.periodStartMs),
                "period_end_ms": String(channelCount.periodEndMs)
            ]
        )
    }

    /// Phase 4.7.B-12 — `slack_file_uploaded_aggregate` action event. Single
    /// event per tick (not per-file). Always-emit: на zero count тоже эмитится
    /// (substrate continuity). `signal_type=.action` (uploading file —
    /// triggering action, не state). Payload flatten'ит typesSummary в top-level
    /// keys (`image_count` / `code_count` / `doc_count` / `other_count`) для
    /// query-friendly access — SQL может фильтровать по type без JSON-функций.
    /// Bucket с zero — пишем 0 explicit (consumer не угадывает "ключ
    /// отсутствует == 0 ИЛИ pre-4.7.B без bucket'а").
    /// ADR-010: filename / preview / permalink — отбрасываются на provider-side
    /// parsing'е, в payload не попадают.
    static func makeFileUploadedAggregateEvent(
        summary: SlackFileUploadSummary,
        nowMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_file_uploaded_aggregate",
                "count": String(summary.count),
                "image_count": String(summary.typesSummary["image"] ?? 0),
                "code_count": String(summary.typesSummary["code"] ?? 0),
                "doc_count": String(summary.typesSummary["doc"] ?? 0),
                "other_count": String(summary.typesSummary["other"] ?? 0),
                "period_start_ms": String(summary.periodStartMs),
                "period_end_ms": String(summary.periodEndMs)
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
