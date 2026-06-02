//
//  SlackCollector.swift
//  LeafCore
//
//  Phase 4.4 B6 — Slack REST polling collector. Mirrors the Linear/GitHub
//  collector pattern with two Slack-specific deviations:
//   1. The per-tick result aggregates messages per channel (1 RawEvent per
//      (channel, count, tick) — D6) and detects huddle transitions by comparing
//      against the last DB event (`Database.readLatestSlackHuddleEvent`).
//   2. workspaceID is stored in the format "<team_id>:<user_id>" (see SlackOAuthService
//      persistence shape, B2). The collector splits out user_id for logging /
//      defensive guarding, but the `from:me` query alias makes userID non-required
//      for the search query — it is kept in the provider signature in case of a
//      fallback path.
//
//  Atomic write: events + offset go in a single transaction via
//  `writeEventsAndOffset`. If the batch is empty and there is no transition, the
//  cursor does not advance (retry next tick on the same `since`), identically to Linear/GitHub.
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
    /// Phase Track-1 D1 — max threads fan-out'ed per tick. Defaults to Int.max
    /// (no cap) so existing tests and stub paths are unaffected. Production wiring
    /// in LeafAgent injects SlackBudgets.maxThreadsPerTick (moat constant).
    private let maxThreadsPerTick: Int

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Phase 4.7.A — last emitted custom-status emoji. In-memory, reset on restart.
    /// `nil` = not yet observed in this process (first tick always emits). Acceptable
    /// double-emit on crash-restart — emoji rarely changes (user set it deliberately),
    /// duplicates are dedupable downstream via the same `transition_at`.
    private var lastEmittedStatusEmoji: String?

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
        /// Phase 4.7.A — number of slack_thread_reply_aggregate events emitted in this tick.
        public let threadReplyEventsEmitted: Int
        /// Phase 4.7.A — true if a slack_status_change was emitted in this tick.
        public let statusChangeEmitted: Bool
        /// Phase 4.7.B-9 — true if a slack_presence_state pulse was emitted in this tick.
        /// Should be true for every non-skipped tick (always-emit semantics).
        public let presenceStateEmitted: Bool
        /// Phase 4.7.B-10 — true if a slack_dnd_state pulse was emitted in this tick.
        /// Should be true for every non-skipped tick (always-emit semantics).
        public let dndStateEmitted: Bool
        /// Phase 4.7.B-11 — number of slack_mention_received_aggregate events emitted
        /// in this tick (one event per channel-bucket, count=mentions per period).
        /// 0 = no mentions / graceful degrade on provider-throw / ratelimit.
        public let mentionEventsEmitted: Int
        /// Phase 4.7.B-12 — true if a `slack_file_uploaded_aggregate` was emitted
        /// in this tick. Should be true for every non-skipped tick
        /// (always-emit semantics — substrate continuity, mirror to presence/dnd).
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

        // 2. Refresh if needed. .refreshDenied → refresher has already done
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

        // 3. Parse userID from workspaceID "<team>:<user>" — the format is guaranteed
        // by SlackOAuthService persistence (B2). Defensive: malformed → skip.
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
        // continuity discipline: even on a network throw we emit a pulse with state="unknown"
        // so downstream sees "observed but undeterminable" without gaps between ticks.
        // The provider impl degrades gracefully on 401/429/parse, but a network throw
        // bubbles up — we wrap it here.
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

        // 5b. Phase 4.7.B-10 — DND pulse. Same observability discipline as
        // fetchPresence: graceful `.empty` on a network throw so the tick is not
        // blocked. The provider impl degrades gracefully on 401/429/parse, but a
        // network throw bubbles up — we wrap it here.
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

        // 5c. Phase 4.7.B-11 — mentions received aggregate. Per-channel counts of
        // messages that mention me over the period `[since, now]` (bootstrap
        // window — provider-side, 7 days by default). Graceful: throw → []
        // (no events emitted by this mechanism). Period semantics: `since` =
        // tick cursor (or 0 on the bootstrap path — the provider handles it).
        // Mentions are NOT message activity (from me); they are received-from-others.
        // We do not advance the cursor for mention search — the window overlaps
        // tick-to-tick and what matters to us is a `periodic snapshot`, not exact delta dedup.
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
        // Always emit (mirror to presence/dnd substrate continuity): a graceful
        // network throw → `.empty(...)` with count=0, types empty. Provider-side
        // 401/429/parse also degrade to `.empty(...)`. ADR-010: filenames /
        // previews / permalinks are dropped during provider-side parsing.
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
        // 6a. Message events — one Action RawEvent per (channel, count > 0).
        let messageEvents: [RawEvent] = tick.channelMessageCounts
            .filter { $0.count > 0 }
            .map {
                Self.makeMessageEvent(
                    channel: $0,
                    periodStartMs: tick.periodStartMs,
                    periodEndMs: tick.periodEndMs
                )
            }

        // 6a'. Phase 4.7.A / Track-1 D1 — thread reply aggregate events.
        //
        // OLD path (pre-D1): count-only events from threadReplyCount field.
        // NEW path (D1): conversations.replies fan-out per active thread found
        // in messages field. Fan-out is bounded by maxThreadsPerTick (moat constant
        // injected at init, defaults to Int.max for tests/stub).
        //
        // When messages field is populated (ProdSlackAPIProvider), we use fan-out.
        // When messages field is nil (stub/test without per-message data), we fall
        // back to old count-only approach for backward compat.
        let hasPerMessageData = tick.channelMessageCounts.contains { $0.messages != nil }
        var threadReplyEvents: [RawEvent] = []
        if hasPerMessageData {
            // D1 fan-out path: collect (channelID, threadTs) tuples from messages
            // where threadTs is non-nil (message belongs to a thread).
            // De-dupe by (channelID, threadTs), take prefix(maxThreadsPerTick).
            var seen = Set<String>()
            var threads: [(channelID: String, threadTs: String)] = []
            for channel in tick.channelMessageCounts {
                for msg in (channel.messages ?? []) {
                    guard let threadTs = msg.threadTs else { continue }
                    let key = "\(msg.channelID):\(threadTs)"
                    if seen.insert(key).inserted {
                        threads.append((channelID: msg.channelID, threadTs: threadTs))
                    }
                }
            }
            let limited = Array(threads.prefix(maxThreadsPerTick))
            for thread in limited {
                let threadSourceID = "slack:thread:\(thread.channelID):\(thread.threadTs)"
                // Read per-thread cursor from collector_offsets.
                let cursor: String?
                do {
                    let offset = try database.readOffset(
                        collectorID: CollectorID.slackPolling,
                        sourceID: threadSourceID
                    )
                    if let lastMs = offset?.lastModifiedMs, lastMs > 0 {
                        // Convert ms back to Slack ts format (seconds.microseconds).
                        let secs = Double(lastMs) / 1000.0
                        cursor = String(format: "%.6f", secs)
                    } else {
                        cursor = nil
                    }
                } catch {
                    logger.error("readOffset thread failed: \(String(describing: error), privacy: .public)")
                    cursor = nil
                }

                let batch: SlackThreadReplyBatch
                do {
                    batch = try await provider.fetchThreadReplies(
                        accessToken: refreshed.accessToken,
                        channelID: thread.channelID,
                        threadTs: thread.threadTs,
                        ownerUserID: userID,
                        oldest: cursor
                    )
                } catch is RateLimitError {
                    logger.warning("fetchThreadReplies 429 for thread \(thread.threadTs, privacy: .public) — breaking fan-out")
                    break
                } catch {
                    logger.error("fetchThreadReplies failed: \(String(describing: error), privacy: .public)")
                    continue
                }

                // Build event and advance cursor.
                let event = Self.makeThreadReplyFanOutEvent(
                    batch: batch,
                    channelID: thread.channelID,
                    threadTs: thread.threadTs,
                    periodStartMs: tick.periodStartMs,
                    periodEndMs: tick.periodEndMs
                )
                threadReplyEvents.append(event)

                // Advance per-thread cursor to latest reply ts.
                let allRecords = ([batch.parent].compactMap { $0 }) + batch.replies
                let latestTsMs: Int64? = allRecords.compactMap { rec -> Int64? in
                    guard let secs = Double(rec.ts) else { return nil }
                    return Int64(secs * 1000)
                }.max()

                if let latestMs = latestTsMs {
                    let threadOffset = CollectorOffset(
                        collectorID: CollectorID.slackPolling,
                        sourceID: threadSourceID,
                        byteOffset: 0,
                        inode: nil,
                        size: 0,
                        lastModifiedMs: latestMs,
                        updatedMs: Int64(now.timeIntervalSince1970 * 1000)
                    )
                    do {
                        try database.writeEventsAndOffset([], offset: threadOffset)
                    } catch {
                        logger.error("persist thread cursor failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } else {
            // Fallback: count-only events (pre-D1 path, stub / no per-message data).
            threadReplyEvents = tick.channelMessageCounts
                .filter { $0.threadReplyCount > 0 }
                .map {
                    Self.makeThreadReplyEvent(
                        channel: $0,
                        periodStartMs: tick.periodStartMs,
                        periodEndMs: tick.periodEndMs
                    )
                }
        }

        // 6b. Huddle transition event — emit only if the state differs from the
        // last DB-recorded huddle event. .unknown → skip
        // (provider could not fetch). First ever event (DB empty) → emit
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

        // 6c. Phase 4.7.A — slack_status_change event. Compare the current emoji
        // against the last-emitted one (in-memory). Different → emit. Idle ticks (same
        // emoji) → no emit. First-ever observation per process always emits
        // (lastEmittedStatusEmoji=nil), which is an acceptable double-emit on restart.
        var statusChangeEvent: RawEvent?
        if tick.statusEmoji != lastEmittedStatusEmoji {
            statusChangeEvent = Self.makeStatusChangeEvent(
                emoji: tick.statusEmoji,
                expirationTs: tick.statusExpirationTs,
                now: now
            )
            lastEmittedStatusEmoji = tick.statusEmoji
        }

        // 6d. Phase 4.7.B-9 — slack_presence_state pulse. ALWAYS emit (per-tick
        // pulse, mirror to gh_notifications_pulse). `nowMs` is computed below
        // in step 7 for the cursor — we compute it earlier to pass into the event.
        let nowMsForPresence = Int64(now.timeIntervalSince1970 * 1000)
        let presenceEvent = Self.makePresenceStateEvent(
            state: presenceState,
            nowMs: nowMsForPresence
        )

        // 6e. Phase 4.7.B-10 — slack_dnd_state pulse. ALWAYS emit (per-tick),
        // the same `nowMs` as presence (one observation timestamp per tick).
        let dndEvent = Self.makeDNDStateEvent(
            state: dndState,
            nowMs: nowMsForPresence
        )

        // 6f. Phase 4.7.B-11 — mention_received_aggregate events. One event
        // per channel-bucket with count > 0 (the provider guarantees count > 0 in
        // groups, but a belt-and-suspenders filter here). We do not create a count=0
        // buffer — the provider drops channels without matches before returning.
        let mentionEvents: [RawEvent] = mentionCounts
            .filter { $0.count > 0 }
            .map { Self.makeMentionReceivedAggregateEvent(channelCount: $0, nowMs: nowMsForPresence) }

        // 6g. Phase 4.7.B-12 — slack_file_uploaded_aggregate. Single event per
        // tick (NOT per-file). Always emit — mirror to presence/dnd: on a zero count
        // we also emit (substrate continuity, downstream sees "observed, no files"
        // vs "not observed"). Flatten typesSummary into top-level keys
        // (image_count / code_count / doc_count / other_count) for query-friendly
        // SQL access.
        let fileUploadEvent = Self.makeFileUploadedAggregateEvent(
            summary: filesSummary,
            nowMs: nowMsForPresence
        )

        // Compose tick events. Split into local slices so the Swift type-checker
        // does not choke on a long chained-`+` expression.
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
        // ADR-010 boundary: only counts / public-safe identifiers / enums /
        // emoji literal. No message text / file names / mention bodies
        // get in (the provider does not parse them, building the dict here is
        // defensive — we build it from already-redacted snapshots).
        // JSONSerialization-friendly: Int / Bool / String / [String: Any].
        // Optional ts → 0 per plan literal (the downstream parser checks for
        // presence via > 0 or a string comparison with "" for the channel).
        let slackPresence: [String: Any] = Self.buildSlackPresenceState(
            tick: tick,
            presenceState: presenceState,
            dnd: dndState,
            mentions: mentionCounts,
            files: filesSummary
        )

        // 8. Atomic write events + cursor + presence_state.
        // The cursor advances only when the provider returned a nonempty cursorMs (i.e.
        // there were messages in the batch). Empty batch + no transition → the cursor
        // stays (retry next tick), like Linear/GitHub.
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

    /// Phase 4.7.B-13 — composite `presence_state.slack` snapshot. The single point
    /// of truth for Slack-side state visible to the team via the Phase 5 broadcast.
    /// Built from tick fetch outputs (already redacted during provider parsing).
    ///
    /// Plan-required keys (top-level):
    /// - `native_presence: String` — "active" | "away" | "unknown" (raw value
    ///   `SlackPresenceState`, mirror of the API enum).
    /// - `dnd: [String: Any]` — nested dict with 4 keys:
    ///     - `is_active: Bool` — `dnd.dndEnabled`.
    ///     - `snooze_until_ms: Int64` — user-set snooze, 0 if nil (per plan literal).
    ///     - `next_dnd_start_ms: Int64` — scheduled DND start, 0 if nil.
    ///     - `next_dnd_end_ms: Int64` — scheduled DND end, 0 if nil.
    /// - `status_emoji: String` — Slack custom status emoji (Phase 4.7.A), empty
    ///   string if not set.
    /// - `status_expiration_ts: Int64` — epoch ms when the status expires (0 = no expiration).
    /// - `in_huddle: Bool` — `tick.huddle == .inAHuddle` (`.unknown` / `.defaultUnset` → false).
    /// - `huddle_channel: String` — channel name where huddle is active. **Currently
    ///   always `""`** — the `SlackHuddleState` enum does not carry channel info at the
    ///   API level (`profile.huddle_state` returns only the enum). The surface is reserved
    ///   for a potential extension of API parsing; downstream readers must NOT
    ///   treat "" = "no huddle" — `in_huddle` exists for that.
    /// - `last_activity_channel: String` — most-recent-message channel over the tick window
    ///   (max-count entry in `tick.channelMessageCounts`); `""` if no messages
    ///   authored.
    /// - `mention_count_today: Int` — sum of mention counts across all channels in the
    ///   tick window. The "today" naming is semantic intent (Slack `after:` has
    ///   day-resolution); in practice it is an intra-tick aggregate (the provider returns
    ///   per-channel counts over the window `[since, now]`, which we sum). We do not read
    ///   it from the DB — each tick is a fresh snapshot.
    /// - `file_count_today: Int` — `filesSummary.count`, naming mirrors mention.
    ///
    /// ADR-010 redaction: caller responsibility. `tick.statusEmoji` — pure literal
    /// (the provider drops the `status_text` body). `last_activity_channel` — public
    /// channel name or the literal "DM" (anonymized in the provider). Mention/file
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
            // huddle_channel: the surface is reserved, the current API parser does
            // not populate it — the `SlackHuddleState` enum is only an indicator, without a channel.
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
        // Aggregate event — timestamp = period boundary, not an individual
        // message ts (count > 1 has no single moment).
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackMessageAuthored.rawValue,
            "channel_name": channel.channelName,
            "count": String(channel.count),
            "period_start_ms": String(periodStartMs),
            "period_end_ms": String(periodEndMs)
        ]
        // Phase 4.6.A.3 — reactions_count present ↔ "we know there were reactions".
        // Absence of the key = "0 reactions or an old alpha.6 without 4.6.A.3"
        // (consistent with the decision not to distinguish 0 from nil in the UI; the SQL
        // aggregator filters `IS NOT NULL` so 0-samples are not confused with pre-4.6 events).
        if channel.reactionsCount > 0 {
            payload["reactions_count"] = String(channel.reactionsCount)
        }
        // Phase Track-1 D1 — per-message records (BodyCap-applied at moat boundary).
        // Emit `messages_json` key when provider populated the messages field.
        // NO top-level `body` key for this event_kind — multiple messages per tick,
        // no single canonical body (consistent with spec §3.5 / §4.4).
        // If any message text contains the BodyCap sentinel "[truncated:" → set body_truncated.
        if let messages = channel.messages, !messages.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(messages),
               let str = String(data: data, encoding: .utf8) {
                payload[Schema.EventPayloadKeys.messagesJson] = str
            }
            let anyTruncated = messages.contains { $0.text.contains("[truncated:") }
            if anyTruncated {
                payload[Schema.EventPayloadKeys.bodyTruncated] = "true"
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.A — thread reply aggregate event (count-only fallback path).
    /// Used when per-message data is not available (stub / pre-D1 path).
    /// Same shape pattern as `message_authored_aggregate`, distinct event_kind.
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

    /// Phase Track-1 D1 — thread reply fan-out event from `conversations.replies`.
    /// Carries top-level `body` (parent text, BodyCap-applied at provider boundary)
    /// + `thread_replies_json` (per-reply records). Parent body_truncated set if
    /// parent text contains the BodyCap sentinel "[truncated:".
    private static func makeThreadReplyFanOutEvent(
        batch: SlackThreadReplyBatch,
        channelID: String,
        threadTs: String,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": "slack_thread_reply_aggregate",
            "channel_id": channelID,
            "thread_ts": threadTs,
            "reply_count": String(batch.replies.count),
            "period_start_ms": String(periodStartMs),
            "period_end_ms": String(periodEndMs)
        ]
        // Parent body (BodyCap-applied at moat boundary).
        if let parent = batch.parent, !parent.text.isEmpty {
            payload[Schema.EventPayloadKeys.body] = parent.text
            if parent.text.contains("[truncated:") {
                payload[Schema.EventPayloadKeys.bodyTruncated] = "true"
            }
        }
        // Per-reply records as JSON array.
        if !batch.replies.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(batch.replies),
               let str = String(data: data, encoding: .utf8) {
                payload[Schema.EventPayloadKeys.threadRepliesJson] = str
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.A — slack_status_change context event. Emoji = pure literal
    /// (e.g. ":pizza:") or "" if cleared. ADR-010: we do NOT read status_text
    /// during parsing (the provider drops the field before payload-finalize).
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

    /// Phase 4.7.B-9 — `slack_presence_state` per-tick pulse event. Mirrors
    /// `gh_notifications_pulse`: emitted on EVERY non-skipped tick (even on
    /// `.unknown` — observation continuity > shrunk row count). `signal_type=.context`
    /// (state pulse, not a user action). Payload — minimal enum + observed ts; nothing
    /// PII (ADR-010), the `users.getPresence` response inherently contains no body.
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
    /// semantics (mirror to `slack_presence_state`): tick → 1 event regardless
    /// of state. `signal_type=.context` (DND is a state, not a user action).
    /// Optional ts payload keys — omitted when nil (consistent with completion_seconds
    /// and other existing conventions; downstream treats absence = "no scheduled" /
    /// "no active snooze"). ADR-010: the response contains no body / PII.
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

    /// Phase 4.7.B-11 — `slack_mention_received_aggregate` action event. One
    /// event per channel-bucket (count > 0). Mirrors the shape of `message_authored_aggregate`
    /// (channel + count + period boundaries), but `event_kind` is distinct so
    /// downstream insights can distinguish "what I wrote" vs "how many times
    /// I was mentioned". `signal_type=.action` (per plan): a mention is a
    /// triggering event for me (needs a response), not a passive state.
    /// ADR-010: the text of the mentioning message and the author of the mention — the provider
    /// drops them during parsing, they do not end up in the payload.
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
    /// event per tick (not per-file). Always-emit: it is also emitted on a zero count
    /// (substrate continuity). `signal_type=.action` (uploading a file is a
    /// triggering action, not a state). The payload flattens typesSummary into top-level
    /// keys (`image_count` / `code_count` / `doc_count` / `other_count`) for
    /// query-friendly access — SQL can filter by type without JSON functions.
    /// A zero bucket — we write 0 explicitly (the consumer does not guess "key
    /// absent == 0 OR pre-4.7.B without the bucket").
    /// ADR-010: filename / preview / permalink — dropped during provider-side
    /// parsing, they do not end up in the payload.
    /// Phase Track-1 D1 — `attachments_json` key added when provider populated
    /// the files field with per-file metadata. Uses shared `AttachmentMeta` shape
    /// for cross-provider uniformity.
    static func makeFileUploadedAggregateEvent(
        summary: SlackFileUploadSummary,
        nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
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
        // Phase Track-1 D1 — per-file metadata as AttachmentMeta for uniform
        // cross-provider payload shape (name + mime + size_bytes).
        if let files = summary.files, !files.isEmpty {
            let attachments = files.map { f in
                AttachmentMeta(name: f.name, mime: f.mimetype, sizeBytes: f.size)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(attachments),
               let str = String(data: data, encoding: .utf8) {
                payload[Schema.EventPayloadKeys.attachmentsJson] = str
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    private static func makeHuddleEvent(state: SlackHuddleState, now: Date) -> RawEvent {
        // Transition timestamp = `now` (not the moment of the huddle start itself) —
        // we do not know the exact moment between ticks; a ±5min inaccuracy is acceptable in the MVP.
        RawEvent(
            timestamp: now,
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackHuddleStateChange.rawValue,
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
