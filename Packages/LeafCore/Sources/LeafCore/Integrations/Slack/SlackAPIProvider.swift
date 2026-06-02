//
//  SlackAPIProvider.swift
//  LeafCore
//
//  Phase 4.4 — protocol for Slack tick polling. One tick = (huddle state from
//  users.profile.get) + (message counts batched per channel from search.messages
//  with the query `from:me after:<DATE>`). The prod implementation (HTTP, JSON parsing,
//  ADR-010 enforcement: we drop bodies/permalinks; DM names → "DM"
//  bucket) lives in LeafCorePrivate (moat). The public Stub returns .empty —
//  CI builds compile, runtime is a no-op.
//

import Foundation

// Note: `SlackScopesChecking` protocol now lives in `SlackScopesChecking.swift`
// (Task 8 extracted it into its own file alongside `SlackScopesService`).

public protocol SlackAPIProvider: Sendable {
    /// One tick = (huddle state + message counts batched per channel since `since`).
    /// `since` — epoch ms cursor (max ts ms from the previous batch; nil → bootstrap
    /// 7-day window backwards). `userID` — Slack user id from the integration record;
    /// the search query uses `from:me` (alias of the authorized user), userID
    /// is kept in the signature for the fallback path / diagnostics.
    func fetchTick(
        accessToken: String,
        userID: String,
        since: Int64?,
        now: Date
    ) async throws -> SlackTickResult

    /// Phase 4.7.B-9 — Slack `users.getPresence` (Tier 3). Returns "active" | "away"
    /// for the authorized user (i.e. self). `userID` is required by the Slack API
    /// signature even for a self-call. Graceful: 401/429/network/parse fail →
    /// `.unknown` (the collector STILL emits a pulse so that downstream maintains
    /// continuity — absence of an event != absence of observation).
    /// ADR-010: the response body contains no PII (only the presence enum).
    func fetchPresence(
        accessToken: String,
        userID: String
    ) async throws -> SlackPresenceState

    /// Phase 4.7.B-10 — Slack `dnd.info` (Tier 3). Returns the current DND state
    /// + scheduled DND window + user-set snooze (until which ts it is silent).
    /// Self-call (the user requests their own dnd state); `userID` is required by the Slack API
    /// signature. Graceful: 401/429/network/parse fail → `.empty`. The collector STILL
    /// emits a pulse — `slack_dnd_state` per-tick observation continuity.
    /// ADR-010: the response contains no body / PII — only booleans + ts.
    func fetchDND(
        accessToken: String,
        userID: String
    ) async throws -> SlackDNDState

    /// Phase 4.7.B-11 — `search.messages?query=<@USER_ID>+after:<sinceISO>`.
    /// Tier 2 endpoint. Returns per-channel aggregate counts of messages in
    /// which the user was mentioned (`<@USER_ID>` — canonical Slack mention syntax).
    /// `since` — epoch ms (the collector provides cursor / nowMs - bootstrap),
    /// converted to `YYYY-MM-DD` (Slack's `after:` has day-resolution).
    /// DM channels (is_im / is_mpim) → bucket "DM" (anonymization, ADR-010).
    /// ADR-010: `match.text` (the mentioning message itself) and `match.user` (who
    /// mentioned) — we do NOT read; that is body / from-user attribution, not our cardinality.
    /// Graceful degrade: 401/429/network/parse fail → `[]` (no events emitted).
    func fetchMentionsReceived(
        accessToken: String,
        userID: String,
        since: Int64
    ) async throws -> [SlackMentionChannelCount]

    /// Phase 4.7.B-12 — `search.files?query=from:me+after:<sinceISO>&count=100`.
    /// Tier 2 endpoint. Returns aggregate count + mime-type bucket distribution
    /// of files the user uploaded in the `[since, now]` window. Single aggregate per tick
    /// (not per-file) — we want a volume picture of "how much and of what type", not an
    /// individual file timeline.
    /// `since` — epoch ms; the provider converts to UTC `YYYY-MM-DD` (Slack's
    /// `after:` has day-resolution).
    /// ADR-010: filenames (`file.name` / `file.title` / `file.permalink_*`),
    /// preview text (`file.preview` / `file.preview_highlight`), thumbs
    /// (`file.thumb_*`) — we NEVER read. We extract ONLY `file.mimetype`
    /// for bucketing; everything else is ignored at parsing.
    /// Buckets (provider-side): `image` / `code` / `doc` / `other`.
    /// Graceful degrade: 401/429/network/parse fail → `.empty(...)` with count=0,
    /// empty types; the collector STILL emits an aggregate event (substrate
    /// continuity — absence of an event != absence of observation).
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

    /// Phase Track-3 D3 — fetch warm-tier (15m) batch in one orchestrated round-trip.
    /// Per-endpoint failure tolerance lives in the implementation; protocol guarantees
    /// a `SlackWarmBatch` (possibly partially `.empty`) on success. Prior-snapshot
    /// arguments allow the implementation / collector to short-circuit diffs and
    /// preserve cursor-style semantics (id-set / per-channel id-list / latestTs rank).
    /// `since` — epoch ms cursor (nil = bootstrap, no diffs emitted, just persist snapshots).
    func fetchWarmState(
        accessToken: String,
        userID: String,
        scopes: SlackScopesChecking,
        priors: SlackWarmStatePriorSnapshots,
        since: Int64?,
        now: Int64
    ) async throws -> SlackWarmBatch

    /// Phase Track-3 D3 — fetch cold-tier (4am local daily) batch. `topChannels`
    /// constrains per-channel fan-out (canvases, channels_info) to the same top-10
    /// member-channels set the warm tier surfaced, preventing unbounded per-cold-tick
    /// HTTP cost. Per-endpoint failure tolerance lives in the implementation.
    func fetchColdState(
        accessToken: String,
        userID: String,
        scopes: SlackScopesChecking,
        topChannels: SlackMemberChannelsTopList,
        now: Int64
    ) async throws -> SlackColdBatch
}

/// Result of one Slack tick. Huddle state — point-in-time snapshot;
/// channel counts — aggregated over the [since, now] window.
/// `cursorMs` = max(ts ms) across processed messages (advance cursor for the next tick),
/// `nil` if there were no messages in the batch — the cursor does not move.
/// Phase 4.7.A: + statusEmoji / statusExpirationTs (Slack custom status). ADR-010:
/// `status_text` (body) is NOT extracted on the provider-side.
public struct SlackTickResult: Sendable, Hashable {
    public let huddle: SlackHuddleState
    public let channelMessageCounts: [SlackChannelMessageCount]
    public let cursorMs: Int64?
    public let periodStartMs: Int64
    public let periodEndMs: Int64
    /// Phase 4.7.A — Slack custom status emoji (e.g. ":pizza:"), empty string if
    /// not set. ADR-010: status_text (body) — we IGNORE at parsing.
    public let statusEmoji: String
    /// Phase 4.7.A — epoch ms when the status expires (0 = no expiration).
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

/// Huddle state as returned by Slack `users.profile.get` in `profile.huddle_state`.
/// rawValue matches the API string 1-to-1 (without an explicit rawValue Swift would generate
/// "defaultUnset" / "inAHuddle", and `init(rawValue:)` would not map the Slack response).
/// `.unknown` — sentinel: the provider failed to parse (forward-compat for
/// future states or the 401/ratelimited path) → the collector does NOT emit a transition,
/// to avoid producing noisy events.
public enum SlackHuddleState: String, Sendable, Hashable {
    case unknown = "unknown"
    case defaultUnset = "default_unset"
    case inAHuddle = "in_a_huddle"

    /// Forward-compat: unknown Slack values → .unknown.
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

/// Bucket: number of self-authored messages in one channel over the tick period.
/// `channelName` — the channel's public name ("engineering"), or the literal `"DM"` for
/// IM/MPIM (one bucket for all DMs — anonymization, ADR-010).
/// `reactionsCount` (Phase 4.6.A.3) — sum over `match.reactions[].count` of all
/// of the channel's messages in the tick window (aggregate numeric only; emoji name / users —
/// never read, ADR-010).
/// `threadReplyCount` (Phase 4.7.A) — subset of `count` where `thread_ts != ts`
/// (i.e. the message is a reply in someone else's thread, not an initiation). Aggregate
/// numeric. ADR-010: text/permalink are not stored, as before.
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

/// Phase 4.7.B-9 — Slack presence state as returned by `users.getPresence`.
/// rawValue matches the API string ("active" | "away"); `.unknown` — sentinel for
/// graceful degrade (401 / ratelimited / network / parse fail on the provider-side).
/// The collector ALWAYS emits a pulse — on `.unknown` the payload contains state="unknown",
/// so that downstream sees observation continuity without gaps between ticks.
public enum SlackPresenceState: String, Sendable, Hashable {
    case active
    case away
    case unknown
}

/// Phase 4.7.B-10 — Slack DND snapshot as returned by `dnd.info`.
/// `dndEnabled` — true if the user is currently in DND (either a scheduled DND window is
/// currently active, or a user-set snooze is active). Slack returns this directly in the
/// `dnd_enabled` field; we additionally OR it with `snooze_endtime > now` defensively.
/// `snoozeUntilMs` — user-set snooze (e.g. "Pause notifications for 1h"),
/// 0 / nil = no active snooze.
/// `nextDNDStartMs` / `nextDNDEndMs` — scheduled DND window (recurring user
/// schedule). 0 / nil = no scheduled DND.
/// All ts are converted to epoch ms (Slack returns seconds → multiply by 1000).
/// `.empty` = "couldn't determine" (graceful degrade on 401/429/network/parse).
/// ADR-010: the response contains no body content or PII.
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

    /// Graceful sentinel: the provider could not determine the state (401 / 429 / network /
    /// parse fail). The collector emits a pulse with `dnd_enabled=false` — downstream
    /// sees observation continuity without gaps between ticks.
    public static let empty = SlackDNDState(
        dndEnabled: false,
        snoozeUntilMs: nil,
        nextDNDStartMs: nil,
        nextDNDEndMs: nil
    )
}

/// Phase 4.7.B-11 — per-channel aggregate "how many times I was mentioned" in
/// the `[periodStartMs, periodEndMs]` window. Mirrors the shape of `SlackChannelMessageCount`
/// (channel name + count + period boundaries), but the semantics differ: not authored,
/// but received-as-mention. DM channels collapse into the literal bucket "DM"
/// (ADR-010 anonymization, like the existing message aggregate).
/// Period boundaries — derived by the collector from `since` / `nowMs` so that downstream
/// can nominally compute "mentions per hour" without re-fetching cursor history.
public struct SlackMentionChannelCount: Sendable, Hashable {
    /// Public channel name ("engineering") or the literal "DM" for IM/MPIM.
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

/// Phase 4.7.B-12 — aggregate snapshot of files the user uploaded in the tick window.
/// `count` — total files (sum across all buckets). `typesSummary` — count
/// per mime-type bucket; canonical buckets `"image"` / `"code"` / `"doc"` /
/// `"other"`. A zero-count bucket is omittable (the consumer flattens — a missing
/// key is read as 0).
/// Period boundaries — derived by the collector / provider from `since` / `nowMs`,
/// downstream can nominally compute "files per hour" without re-fetching the cursor.
/// `.empty(...)` — graceful sentinel when the provider could not fetch (401/429/parse);
/// the collector emits an aggregate with count=0 so that downstream sees observation continuity.
/// ADR-010: filename / preview / permalink / thumbs — are NEVER read on the
/// provider-side; the provider extracts only the mimetype for bucketing.
/// `files` (Phase Track-1 D1) — optional per-file metadata populated by
/// ProdSlackAPIProvider. Existing consumers that only read `count`/`typesSummary`
/// are unaffected (additive field, default nil).
public struct SlackFileUploadSummary: Sendable, Hashable {
    public let count: Int
    /// Canonical buckets: "image" / "code" / "doc" / "other". A bucket with 0 files —
    /// may be absent; the consumer flattens (default 0).
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

    /// Graceful sentinel: the provider could not determine the state (401 / 429 / network /
    /// parse fail). The collector emits an aggregate event with count=0 — downstream
    /// sees observation continuity without gaps between ticks.
    public static func empty(periodStartMs: Int64, periodEndMs: Int64) -> SlackFileUploadSummary {
        SlackFileUploadSummary(
            count: 0,
            typesSummary: [:],
            periodStartMs: periodStartMs,
            periodEndMs: periodEndMs
        )
    }
}

/// Stub for CI / dev-without-moat builds. Never makes an HTTP call, returns
/// `.empty` — the SlackCollector tick runs as a no-op.
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

    public func fetchWarmState(
        accessToken: String,
        userID: String,
        scopes: SlackScopesChecking,
        priors: SlackWarmStatePriorSnapshots,
        since: Int64?,
        now: Int64
    ) async throws -> SlackWarmBatch {
        .empty
    }

    public func fetchColdState(
        accessToken: String,
        userID: String,
        scopes: SlackScopesChecking,
        topChannels: SlackMemberChannelsTopList,
        now: Int64
    ) async throws -> SlackColdBatch {
        .empty
    }
}
