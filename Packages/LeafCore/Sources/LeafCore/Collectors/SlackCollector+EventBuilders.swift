//
//  SlackCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — composite presence-state composer +
//  static event builders for the hot Slack collector (message / thread /
//  status / presence / DND / mention / file / huddle). Pure relocation
//  from SlackCollector.swift.
//

import Foundation

extension SlackCollector {
    static func buildSlackPresenceState(
        tick: SlackTickResult,
        presenceState: SlackPresenceState,
        dnd: SlackDNDState,
        mentions: [SlackMentionChannelCount],
        files: SlackFileUploadSummary
    ) -> [String: Any] {
        let lastActivityChannel =
            tick.channelMessageCounts
            .max(by: { $0.count < $1.count })?
            .channelName ?? ""
        let mentionTotal = mentions.map { $0.count }.reduce(0, +)
        let dndDict: [String: Any] = [
            "is_active": dnd.dndEnabled,
            "snooze_until_ms": dnd.snoozeUntilMs ?? 0,
            "next_dnd_start_ms": dnd.nextDNDStartMs ?? 0,
            "next_dnd_end_ms": dnd.nextDNDEndMs ?? 0,
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
            "file_count_today": files.count,
        ]
    }

    static func makeMessageEvent(
        channel: SlackChannelMessageCount,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) -> RawEvent {
        // Aggregate event — timestamp = period boundary, не индивидуальное
        // message ts (count > 1 не имеет single moment).
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackMessageAuthored.rawValue,
            "channel_name": channel.channelName,
            "count": String(channel.count),
            "period_start_ms": String(periodStartMs),
            "period_end_ms": String(periodEndMs),
        ]
        // Phase 4.6.A.3 — reactions_count present ↔ "знаем что были реакции".
        // Отсутствие ключа = "0 реакций или старая alpha.6 без 4.6.A.3"
        // (consistent с decision не различать 0 от nil на UI; SQL aggregator
        // фильтрует `IS NOT NULL` чтобы 0-samples не путать с pre-4.6 events).
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
                let str = String(data: data, encoding: .utf8)
            {
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
    /// Same shape pattern что `message_authored_aggregate`, distinct event_kind.
    static func makeThreadReplyEvent(
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
                "period_end_ms": String(periodEndMs),
            ]
        )
    }

    /// Phase Track-1 D1 — thread reply fan-out event from `conversations.replies`.
    /// Carries top-level `body` (parent text, BodyCap-applied at provider boundary)
    /// + `thread_replies_json` (per-reply records). Parent body_truncated set if
    /// parent text contains the BodyCap sentinel "[truncated:".
    static func makeThreadReplyFanOutEvent(
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
            "period_end_ms": String(periodEndMs),
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
                let str = String(data: data, encoding: .utf8)
            {
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
    /// (e.g. ":pizza:") или "" если cleared. ADR-010: status_text НЕ читаем
    /// на parsing (provider drop'ает field до payload-finalize).
    static func makeStatusChangeEvent(
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
                "transition_at": String(Int64(now.timeIntervalSince1970 * 1000)),
            ]
        )
    }

    /// Phase 4.7.B-9 — `slack_presence_state` per-tick pulse event. Mirror'ит
    /// `gh_notifications_pulse`: эмитится КАЖДЫЙ non-skipped tick (даже на
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
                "observed_at_ms": String(nowMs),
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
            "observed_at_ms": String(nowMs),
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
                "period_end_ms": String(channelCount.periodEndMs),
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
            "period_end_ms": String(summary.periodEndMs),
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
                let str = String(data: data, encoding: .utf8)
            {
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

    static func makeHuddleEvent(state: SlackHuddleState, now: Date) -> RawEvent {
        // Transition timestamp = `now` (а не moment самого huddle start) —
        // мы не знаем точный момент между ticks; ±5min неточность приемлема в MVP.
        RawEvent(
            timestamp: now,
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackHuddleStateChange.rawValue,
                "state": state.rawValue,
            ]
        )
    }
}
