//
//  SlackAPIProvider.swift
//  LeafCore
//
//  Phase 4.4 — protocol для Slack tick polling. Один tick = (huddle state из
//  users.profile.get) + (message counts batched per channel из search.messages
//  с query `from:me after:<DATE>`). Prod implementation (HTTP, JSON parsing,
//  ADR-010 enforcement: bodies/permalinks отбрасываем; DM names → "DM"
//  bucket) живёт в LeafCorePrivate (moat). Public Stub возвращает .empty —
//  CI builds компилируются, runtime no-op.
//

import Foundation

public protocol SlackAPIProvider: Sendable {
    /// One tick = (huddle state + message counts batched per channel since `since`).
    /// `since` — epoch ms cursor (max ts ms из prev'ого batch'а; nil → bootstrap
    /// 7-day window backwards). `userID` — Slack user id из integration record;
    /// search query использует `from:me` (alias авторизованного юзера), userID
    /// сохранён в сигнатуре на случай fallback path / диагностики.
    func fetchTick(
        accessToken: String,
        userID: String,
        since: Int64?,
        now: Date
    ) async throws -> SlackTickResult

    /// Phase 4.7.B-9 — Slack `users.getPresence` (Tier 3). Returns "active" | "away"
    /// для авторизованного юзера (т.е. self). `userID` обязателен Slack API
    /// signature даже для self-call. Graceful: 401/429/network/parse fail →
    /// `.unknown` (collector ВСЁ РАВНО emit'ит pulse, чтобы downstream ввёл
    /// continuity — отсутствие event'а != отсутствие observation).
    /// ADR-010: тело response ничего PII не содержит (только presence enum).
    func fetchPresence(
        accessToken: String,
        userID: String
    ) async throws -> SlackPresenceState

    /// Phase 4.7.B-10 — Slack `dnd.info` (Tier 3). Returns текущий DND-state
    /// + scheduled DND window + user-set snooze (до какого ts тишина).
    /// Self-call (юзер запрашивает свой dnd state); `userID` обязателен Slack API
    /// signature. Graceful: 401/429/network/parse fail → `.empty`. Collector ВСЁ
    /// РАВНО emit'ит pulse — `slack_dnd_state` per-tick observation continuity.
    /// ADR-010: response не содержит body / PII — только booleans + ts.
    func fetchDND(
        accessToken: String,
        userID: String
    ) async throws -> SlackDNDState
}

/// Результат одного Slack tick'а. Huddle state — point-in-time snapshot;
/// channel counts — aggregated over [since, now] window.
/// `cursorMs` = max(ts ms) across processed messages (advance cursor для next tick),
/// `nil` если в batch'е сообщений не было — cursor не двигается.
/// Phase 4.7.A: + statusEmoji / statusExpirationTs (Slack custom status). ADR-010:
/// `status_text` (body) НЕ извлекается на provider-side.
public struct SlackTickResult: Sendable, Hashable {
    public let huddle: SlackHuddleState
    public let channelMessageCounts: [SlackChannelMessageCount]
    public let cursorMs: Int64?
    public let periodStartMs: Int64
    public let periodEndMs: Int64
    /// Phase 4.7.A — Slack custom status emoji (e.g. ":pizza:"), пустая строка если
    /// не выставлен. ADR-010: status_text (body) ИГНОРИРУЕМ на parsing'е.
    public let statusEmoji: String
    /// Phase 4.7.A — epoch ms когда status истекает (0 = no expiration).
    public let statusExpirationTs: Int64

    public init(
        huddle: SlackHuddleState,
        channelMessageCounts: [SlackChannelMessageCount],
        cursorMs: Int64?,
        periodStartMs: Int64,
        periodEndMs: Int64,
        statusEmoji: String = "",
        statusExpirationTs: Int64 = 0
    ) {
        self.huddle = huddle
        self.channelMessageCounts = channelMessageCounts
        self.cursorMs = cursorMs
        self.periodStartMs = periodStartMs
        self.periodEndMs = periodEndMs
        self.statusEmoji = statusEmoji
        self.statusExpirationTs = statusExpirationTs
    }

    public static let empty = SlackTickResult(
        huddle: .unknown,
        channelMessageCounts: [],
        cursorMs: nil,
        periodStartMs: 0,
        periodEndMs: 0
    )
}

/// Huddle state, как его отдаёт Slack `users.profile.get` в `profile.huddle_state`.
/// rawValue матчит API string 1-в-1 (без явного rawValue Swift сгенерил бы
/// "defaultUnset" / "inAHuddle", и `init(rawValue:)` не маппил бы Slack-ответ).
/// `.unknown` — sentinel: provider не смог распарсить (forward-compat для
/// будущих state'ов или 401/ratelimited path) → collector НЕ emit'ит transition,
/// чтобы не плодить noisy события.
public enum SlackHuddleState: String, Sendable, Hashable {
    case unknown = "unknown"
    case defaultUnset = "default_unset"
    case inAHuddle = "in_a_huddle"

    /// Forward-compat: неизвестные Slack values → .unknown.
    public init(slackAPIString: String) {
        self = SlackHuddleState(rawValue: slackAPIString) ?? .unknown
    }
}

/// Bucket: количество self-authored сообщений в одном канале за период tick'а.
/// `channelName` — public name канала ("engineering"), либо литерал `"DM"` для
/// IM/MPIM (одна корзина на все DMs — anonymization, ADR-010).
/// `reactionsCount` (Phase 4.6.A.3) — sum по `match.reactions[].count` всех
/// сообщений канала в окне tick'а (aggregate numeric only; emoji name / users —
/// никогда не читаются, ADR-010).
/// `threadReplyCount` (Phase 4.7.A) — subset of `count` где `thread_ts != ts`
/// (т.е. message — это reply в чужом thread'е, не initiation). Aggregate
/// numeric. ADR-010: text/permalink не сохраняются как и раньше.
public struct SlackChannelMessageCount: Sendable, Hashable {
    public let channelName: String
    public let count: Int
    public let reactionsCount: Int
    public let threadReplyCount: Int

    public init(
        channelName: String,
        count: Int,
        reactionsCount: Int = 0,
        threadReplyCount: Int = 0
    ) {
        self.channelName = channelName
        self.count = count
        self.reactionsCount = reactionsCount
        self.threadReplyCount = threadReplyCount
    }
}

/// Phase 4.7.B-9 — Slack presence state, как его отдаёт `users.getPresence`.
/// rawValue матчит API string ("active" | "away"); `.unknown` — sentinel для
/// graceful degrade (401 / ratelimited / network / parse fail на provider-side).
/// Collector ВСЕГДА emit'ит pulse — на `.unknown` payload содержит state="unknown",
/// чтобы downstream видел observation continuity без gap'ов между tick'ами.
public enum SlackPresenceState: String, Sendable, Hashable {
    case active
    case away
    case unknown
}

/// Phase 4.7.B-10 — Slack DND snapshot, как его отдаёт `dnd.info`.
/// `dndEnabled` — true если юзер сейчас в DND (либо scheduled DND window сейчас
/// active, либо user-set snooze active). Slack возвращает это напрямую полем
/// `dnd_enabled`; мы дополнительно OR'им с `snooze_endtime > now` defensively.
/// `snoozeUntilMs` — user-set snooze (например "Pause notifications for 1h"),
/// 0 / nil = no active snooze.
/// `nextDNDStartMs` / `nextDNDEndMs` — scheduled DND window (recurring user
/// schedule). 0 / nil = no scheduled DND.
/// Все ts конвертированы в epoch ms (Slack отдаёт seconds → multiply by 1000).
/// `.empty` = "couldn't determine" (graceful degrade на 401/429/network/parse).
/// ADR-010: response не содержит body content или PII.
public struct SlackDNDState: Sendable, Hashable {
    public let dndEnabled: Bool
    public let snoozeUntilMs: Int64?
    public let nextDNDStartMs: Int64?
    public let nextDNDEndMs: Int64?

    public init(
        dndEnabled: Bool,
        snoozeUntilMs: Int64?,
        nextDNDStartMs: Int64?,
        nextDNDEndMs: Int64?
    ) {
        self.dndEnabled = dndEnabled
        self.snoozeUntilMs = snoozeUntilMs
        self.nextDNDStartMs = nextDNDStartMs
        self.nextDNDEndMs = nextDNDEndMs
    }

    /// Graceful sentinel: provider не смог определить state (401 / 429 / network /
    /// parse fail). Collector emit'ит pulse с `dnd_enabled=false` — downstream
    /// видит observation continuity без gap'ов между tick'ами.
    public static let empty = SlackDNDState(
        dndEnabled: false,
        snoozeUntilMs: nil,
        nextDNDStartMs: nil,
        nextDNDEndMs: nil
    )
}

/// Stub для CI / dev-без-moat сборок. Никогда не делает HTTP call, возвращает
/// `.empty` — SlackCollector tick проходит no-op.
public struct StubSlackAPIProvider: SlackAPIProvider {
    public init() {}
    public func fetchTick(
        accessToken: String,
        userID: String,
        since: Int64?,
        now: Date
    ) async throws -> SlackTickResult {
        .empty
    }

    public func fetchPresence(
        accessToken: String,
        userID: String
    ) async throws -> SlackPresenceState {
        .unknown
    }

    public func fetchDND(
        accessToken: String,
        userID: String
    ) async throws -> SlackDNDState {
        .empty
    }
}
