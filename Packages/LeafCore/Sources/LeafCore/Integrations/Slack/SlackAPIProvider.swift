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

    /// Phase 4.7.B-11 — `search.messages?query=<@USER_ID>+after:<sinceISO>`.
    /// Tier 2 endpoint. Возвращает per-channel aggregate count'ы сообщений, в
    /// которых юзер был mention'нут (`<@USER_ID>` — canonical Slack mention syntax).
    /// `since` — epoch ms (collector предоставляет cursor / nowMs - bootstrap),
    /// конвертируется в `YYYY-MM-DD` (Slack `after:` имеет day-resolution).
    /// DM channels (is_im / is_mpim) → bucket "DM" (anonymization, ADR-010).
    /// ADR-010: `match.text` (само mention'ящее сообщение) и `match.user` (кто
    /// mention'ил) — НЕ читаем; это body / from-user attribution, не наша cardinality.
    /// Graceful degrade: 401/429/network/parse fail → `[]` (no events emitted).
    func fetchMentionsReceived(
        accessToken: String,
        userID: String,
        since: Int64
    ) async throws -> [SlackMentionChannelCount]

    /// Phase 4.7.B-12 — `search.files?query=from:me+after:<sinceISO>&count=100`.
    /// Tier 2 endpoint. Returns aggregate count + mime-type bucket distribution
    /// of files юзер uploaded в окне `[since, now]`. Single aggregate per tick
    /// (not per-file) — мы хотим объёмную картину "сколько и какого типа", не
    /// individual file timeline.
    /// `since` — epoch ms; provider конвертирует в UTC `YYYY-MM-DD` (Slack
    /// `after:` имеет day-resolution).
    /// ADR-010: filenames (`file.name` / `file.title` / `file.permalink_*`),
    /// preview text (`file.preview` / `file.preview_highlight`), thumbs
    /// (`file.thumb_*`) — НИКОГДА не читаем. Извлекаем ТОЛЬКО `file.mimetype`
    /// для bucket'ирования; всё остальное игнорируется на parsing'е.
    /// Buckets (provider-side): `image` / `code` / `doc` / `other`.
    /// Graceful degrade: 401/429/network/parse fail → `.empty(...)` с count=0,
    /// типs пустой; collector ВСЁ РАВНО emit'ит aggregate event (substrate
    /// continuity — отсутствие event'а != отсутствие observation).
    func fetchFilesUploaded(
        accessToken: String,
        userID: String,
        since: Int64
    ) async throws -> SlackFileUploadSummary

    /// Phase Track-1 D1 — `conversations.replies` (Tier 3) fan-out for one thread.
    /// Returns parent message + replies for threads where the owner participated.
    /// `channelID` — Slack channel_id (not name). `threadTs` — parent message ts.
    /// `ownerUserID` — authed user ID; replies filtered to owner-authored OR all
    ///   replies in owner-started threads (UC4).
    /// `oldest` — Slack ts cursor string for incremental fetch (nil = from start).
    ///
    /// Throws `RateLimitError.retryAfter(seconds)` on HTTP 429 so collector can
    /// break out of the fan-out loop and preserve per-thread cursors of already-
    /// processed threads.
    ///
    /// ADR-010 §6 amendment: text captured on-device only; relay path (Share Controls
    /// filter applied before encryption) never carries raw text.
    func fetchThreadReplies(
        accessToken: String,
        channelID: String,
        threadTs: String,
        ownerUserID: String,
        oldest: String?
    ) async throws -> SlackThreadReplyBatch
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

/// Phase Track-1 D1 — per-message record captured from `search.messages` `match.text`.
/// BodyCap applied at provider boundary (LeafCorePrivate moat); text here is already
/// capped. ADR-010 §6 amendment: message text allowed on-device only, never relayed.
/// `channelID` enables thread fan-out cursor keying. `threadTs` non-nil → message
/// is either a thread initiation or a reply (use threadTs != ts to distinguish).
public struct SlackMessageRecord: Codable, Sendable, Hashable {
    /// Message timestamp in Slack ts format ("1614800000.000100"). Unique ID per channel.
    public let ts: String
    /// Thread root ts. Non-nil → message belongs to a thread. If `ts == threadTs`
    /// the message started the thread; otherwise it is a reply.
    public let threadTs: String?
    /// Channel ID for thread fan-out cursor keying.
    public let channelID: String
    /// Message text, BodyCap-applied at provider boundary. Empty string if provider
    /// could not read text (permissions / parse failure — graceful degrade).
    public let text: String
    /// Attachments (file uploads within this message). Empty if none.
    public let attachments: [AttachmentMeta]

    enum CodingKeys: String, CodingKey {
        case ts
        case threadTs = "thread_ts"
        case channelID = "channel_id"
        case text
        case attachments
    }

    public init(
        ts: String,
        threadTs: String?,
        channelID: String,
        text: String,
        attachments: [AttachmentMeta] = []
    ) {
        self.ts = ts
        self.threadTs = threadTs
        self.channelID = channelID
        self.text = text
        self.attachments = attachments
    }
}

/// Phase Track-1 D1 — per-file metadata from `search.files` or `search.messages` file
/// attachments. Captures name + mime + size; ADR-010: content / preview / permalink
/// never read. Use `AttachmentMeta(name:mime:sizeBytes:)` for cross-provider uniformity
/// when embedding in event payload.
public struct SlackFileMeta: Codable, Sendable, Hashable {
    public let name: String
    /// IANA MIME type as returned by Slack (e.g. "image/png", "text/plain").
    public let mimetype: String
    /// File size in bytes (Slack `file.size` field). Nil if not present in response.
    public let size: Int?

    public init(name: String, mimetype: String, size: Int?) {
        self.name = name
        self.mimetype = mimetype
        self.size = size
    }
}

/// Phase Track-1 D1 — result of `conversations.replies` fan-out for one thread.
/// `parent` is the top-level message that started the thread (text BodyCap-applied).
/// `replies` are the sub-messages in the thread authored by ownerUserID or belonging
/// to a thread owned by the user (per UC4 spec).
/// `nextCursor` is the Slack `response_metadata.next_cursor` for pagination
/// (nil = no more pages in the window). Used to advance per-thread cursor.
public struct SlackThreadReplyBatch: Sendable {
    /// Parent (root) message of the thread. Nil if the API couldn't fetch it
    /// (e.g., channel no longer accessible) — batch still processable via replies.
    public let parent: SlackMessageRecord?
    /// Reply messages authored by or in a thread of the owner.
    public let replies: [SlackMessageRecord]
    /// Slack response_metadata.next_cursor for this thread. Nil = fully consumed.
    public let nextCursor: String?

    public init(
        parent: SlackMessageRecord?,
        replies: [SlackMessageRecord],
        nextCursor: String?
    ) {
        self.parent = parent
        self.replies = replies
        self.nextCursor = nextCursor
    }

    /// Empty sentinel — used by stub and graceful-degrade paths.
    public static let empty = SlackThreadReplyBatch(parent: nil, replies: [], nextCursor: nil)
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
/// `messages` (Phase Track-1 D1) — optional per-message records with BodyCap-applied
/// text, populated by ProdSlackAPIProvider. Nil for stub / graceful-degrade paths.
/// Existing callers that only read `count` / `reactionsCount` / `threadReplyCount`
/// are unaffected (additive field with default nil).
public struct SlackChannelMessageCount: Sendable, Hashable {
    public let channelName: String
    public let count: Int
    public let reactionsCount: Int
    public let threadReplyCount: Int
    /// Phase Track-1 D1 — per-message records (BodyCap-applied at moat boundary).
    /// Nil = not populated (stub / non-prod path). Empty array = provider returned
    /// no messages for this channel in the tick window (degenerate but valid).
    public let messages: [SlackMessageRecord]?

    public init(
        channelName: String,
        count: Int,
        reactionsCount: Int = 0,
        threadReplyCount: Int = 0,
        messages: [SlackMessageRecord]? = nil
    ) {
        self.channelName = channelName
        self.count = count
        self.reactionsCount = reactionsCount
        self.threadReplyCount = threadReplyCount
        self.messages = messages
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

/// Phase 4.7.B-11 — per-channel aggregate "сколько раз меня mention'нули" в
/// окне `[periodStartMs, periodEndMs]`. Mirror'ит shape `SlackChannelMessageCount`
/// (channel name + count + period boundaries), но семантика другая: not authored,
/// а received-as-mention. DM channels collapse'ятся в literal bucket "DM"
/// (ADR-010 anonymization, как existing message aggregate).
/// Period boundaries — derived collector'ом из `since` / `nowMs` чтобы downstream
/// мог nominally считать "mentions per hour" без re-fetching cursor history.
public struct SlackMentionChannelCount: Sendable, Hashable {
    /// Public channel name ("engineering") или literal "DM" для IM/MPIM.
    public let channelName: String
    public let count: Int
    public let periodStartMs: Int64
    public let periodEndMs: Int64

    public init(
        channelName: String,
        count: Int,
        periodStartMs: Int64,
        periodEndMs: Int64
    ) {
        self.channelName = channelName
        self.count = count
        self.periodStartMs = periodStartMs
        self.periodEndMs = periodEndMs
    }
}

/// Phase 4.7.B-12 — aggregate snapshot of files юзер uploaded в окне tick'а.
/// `count` — total files (sum'а across всех bucket'ов). `typesSummary` — count
/// per mime-type bucket; canonical buckets `"image"` / `"code"` / `"doc"` /
/// `"other"`. Bucket с zero-count omittable (consumer flatten'ит — отсутствующий
/// ключ читаем как 0).
/// Period boundaries — derived collector'ом / provider'ом из `since` / `nowMs`,
/// downstream может nominally считать "files per hour" без re-fetching cursor.
/// `.empty(...)` — graceful sentinel когда provider не смог fetch (401/429/parse);
/// collector emit'ит aggregate с count=0 чтобы downstream видел observation continuity.
/// ADR-010: filename / preview / permalink / thumbs — НИКОГДА не читаются на
/// provider-side; провайдер извлекает только mimetype для bucket'ирования.
/// `files` (Phase Track-1 D1) — optional per-file metadata populated by
/// ProdSlackAPIProvider. Existing consumers that only read `count`/`typesSummary`
/// are unaffected (additive field, default nil).
public struct SlackFileUploadSummary: Sendable, Hashable {
    public let count: Int
    /// Canonical buckets: "image" / "code" / "doc" / "other". Bucket с 0 files —
    /// допустимо отсутствовать; consumer flatten'ит (default 0).
    public let typesSummary: [String: Int]
    public let periodStartMs: Int64
    public let periodEndMs: Int64
    /// Phase Track-1 D1 — per-file metadata (name + mime + size). Nil = not populated
    /// (stub / graceful-degrade path). Empty array = provider returned no files.
    public let files: [SlackFileMeta]?

    public init(
        count: Int,
        typesSummary: [String: Int],
        periodStartMs: Int64,
        periodEndMs: Int64,
        files: [SlackFileMeta]? = nil
    ) {
        self.count = count
        self.typesSummary = typesSummary
        self.periodStartMs = periodStartMs
        self.periodEndMs = periodEndMs
        self.files = files
    }

    /// Graceful sentinel: provider не смог определить state (401 / 429 / network /
    /// parse fail). Collector emit'ит aggregate event с count=0 — downstream
    /// видит observation continuity без gap'ов между tick'ами.
    public static func empty(periodStartMs: Int64, periodEndMs: Int64) -> SlackFileUploadSummary {
        SlackFileUploadSummary(
            count: 0,
            typesSummary: [:],
            periodStartMs: periodStartMs,
            periodEndMs: periodEndMs
        )
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

    public func fetchMentionsReceived(
        accessToken: String,
        userID: String,
        since: Int64
    ) async throws -> [SlackMentionChannelCount] {
        []
    }

    public func fetchFilesUploaded(
        accessToken: String,
        userID: String,
        since: Int64
    ) async throws -> SlackFileUploadSummary {
        .empty(periodStartMs: 0, periodEndMs: 0)
    }

    public func fetchThreadReplies(
        accessToken: String,
        channelID: String,
        threadTs: String,
        ownerUserID: String,
        oldest: String?
    ) async throws -> SlackThreadReplyBatch {
        .empty
    }
}
