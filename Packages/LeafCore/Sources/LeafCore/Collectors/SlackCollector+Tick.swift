//
//  SlackCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration moved
//  out of SlackCollector.swift. Pure relocation; no behavioural change.
//

import Foundation

extension SlackCollector {
    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .slack)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → refresher уже сделал
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch SlackTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — Slack disconnected: \(msg, privacy: .public)")
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
        }

        // 3. Parse userID из workspaceID "<team>:<user>" — формат гарантирован
        // SlackOAuthService persistence (B2). Defensive: malformed → skip.
        let parts = refreshed.workspaceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            logger.error(
                "malformed workspaceID '\(refreshed.workspaceID, privacy: .public)' — expected '<team>:<user>'")
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
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
            return TickResult(
                skipped: true, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
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
            return TickResult(
                skipped: false, messageEventsEmitted: 0, huddleTransitionEmitted: false, cursorAdvancedMs: nil)
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
            .filter { !$0.isEmpty }
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
                    logger.warning(
                        "fetchThreadReplies 429 for thread \(thread.threadTs, privacy: .public) — breaking fan-out")
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
            setLastEmittedStatusEmoji(tick.statusEmoji)
        }

        // 6d. Phase 4.7.B-9 — slack_presence_state pulse. ВСЕГДА emit (per-tick
        // pulse, mirror к gh_notifications_pulse). `nowMs` определяется ниже
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
        let mentionEvents: [RawEvent] =
            mentionCounts
            .filter { !$0.isEmpty }
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
            logger.info(
                "tick wrote \(messageEvents.count, privacy: .public) message + \(threadReplyEvents.count, privacy: .public) thread-reply + \(huddleEvent != nil ? 1 : 0, privacy: .public) huddle + \(statusChangeEvent != nil ? 1 : 0, privacy: .public) status + 1 presence + 1 dnd + \(mentionEvents.count, privacy: .public) mentions + 1 file-upload events, cursor=\(offset.lastModifiedMs, privacy: .public)"
            )
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
}
