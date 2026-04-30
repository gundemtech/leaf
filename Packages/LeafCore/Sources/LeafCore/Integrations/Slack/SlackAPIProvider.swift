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
}

/// Результат одного Slack tick'а. Huddle state — point-in-time snapshot;
/// channel counts — aggregated over [since, now] window.
/// `cursorMs` = max(ts ms) across processed messages (advance cursor для next tick),
/// `nil` если в batch'е сообщений не было — cursor не двигается.
public struct SlackTickResult: Sendable, Hashable {
    public let huddle: SlackHuddleState
    public let channelMessageCounts: [SlackChannelMessageCount]
    public let cursorMs: Int64?
    public let periodStartMs: Int64
    public let periodEndMs: Int64

    public init(
        huddle: SlackHuddleState,
        channelMessageCounts: [SlackChannelMessageCount],
        cursorMs: Int64?,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) {
        self.huddle = huddle
        self.channelMessageCounts = channelMessageCounts
        self.cursorMs = cursorMs
        self.periodStartMs = periodStartMs
        self.periodEndMs = periodEndMs
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
public struct SlackChannelMessageCount: Sendable, Hashable {
    public let channelName: String
    public let count: Int
    public let reactionsCount: Int

    public init(channelName: String, count: Int, reactionsCount: Int = 0) {
        self.channelName = channelName
        self.count = count
        self.reactionsCount = reactionsCount
    }
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
}
