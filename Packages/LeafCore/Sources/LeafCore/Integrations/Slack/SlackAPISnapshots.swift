//
//  SlackAPISnapshots.swift
//  LeafCore
//
//  Phase Track-3 D3 — public value types for Slack warm/cold collector batches and
//  `provider_snapshots` rows. All `Sendable Hashable` per LeafCore convention;
//  snapshots persist as JSON via private inner Codable wrappers in the moat
//  (mirror Linear D1 / GitHub D2 precedent — Codable lives in private inner
//  wrappers translating at snapshot boundaries, not on these public types).
//
//  Each "snapshot" / "batch" type carries `public static let empty` so collectors
//  can short-circuit bootstrap / graceful-degrade paths without per-call ceremony.
//

import Foundation

// MARK: - Member channels (users.conversations full set + fan-out ranking)

/// One channel the authed user is a member of, with the latest message ts the
/// API reported (used for top-N ranking by recency at fan-out time).
/// `latestTs` is `nil` when Slack omitted the field (e.g. channel has no
/// messages or member-only metadata).
public struct SlackMemberChannel: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let latestTs: Int64?

    public init(id: String, name: String, latestTs: Int64?) {
        self.id = id
        self.name = name
        self.latestTs = latestTs
    }
}

/// Set of member channels — interpretation is contextual:
///   • Persisted snapshot (`slackMemberChannels` kind) holds the FULL set —
///     this is the diff source for `slack_channel_joined/_left`. Storing the
///     full set is required to avoid false-positive transitions when channel
///     ranking churns (C3 review fix, D3 follow-up).
///   • As provider input (`fetchColdState.topChannels`) and per-channel
///     fan-out target list (pins/bookmarks/conversations.info), the value is
///     the top-N cap produced by `rankTop10ByLatestTs`. The cap is applied
///     at fan-out time, never to persisted state.
///
/// Type-name retained for minimum-churn fix — the value type is fundamentally
/// `{channels: [SlackMemberChannel]}` regardless of interpretation.
public struct SlackMemberChannelsTopList: Sendable, Hashable, Codable {
    public let channels: [SlackMemberChannel]

    public init(channels: [SlackMemberChannel]) {
        self.channels = channels
    }

    public static let empty = SlackMemberChannelsTopList(channels: [])
}

// MARK: - Reactions (reactions.list scoped to self-authored items)

/// One reaction observed on a self-authored item. `itemRef` is the canonical
/// "channelID:messageTs" composite (or "file:fileID" for file reactions) so
/// downstream consumers can dedupe across emoji and across ticks.
public struct SlackReaction: Sendable, Hashable {
    public let itemRef: String
    public let emoji: String
    public let addedAtMs: Int64

    public init(itemRef: String, emoji: String, addedAtMs: Int64) {
        self.itemRef = itemRef
        self.emoji = emoji
        self.addedAtMs = addedAtMs
    }
}

/// Batch of reactions returned by one warm-tier `reactions.list` fan-out.
public struct SlackReactionsBatch: Sendable, Hashable {
    public let reactions: [SlackReaction]

    public init(reactions: [SlackReaction]) {
        self.reactions = reactions
    }

    public static let empty = SlackReactionsBatch(reactions: [])
}

// MARK: - Pins (per channel id-set diff)

/// Per-channel pin id-set used for set-diff emission. Only item refs (the
/// "channelID:messageTs" composite or "file:fileID") are retained — ADR-010
/// forbids pinned-message body capture in this tier.
public struct SlackChannelPinsSnapshot: Sendable, Hashable, Codable {
    public let channelID: String
    public let pinItemRefs: [String]

    public init(channelID: String, pinItemRefs: [String]) {
        self.channelID = channelID
        self.pinItemRefs = pinItemRefs
    }
}

// MARK: - Bookmarks (per channel)

/// One bookmark on a channel. `title` and `link` are structured user metadata
/// (not message bodies) and are captured directly — these are the bookmark's
/// reason-for-existing fields surfaced by Slack's bookmarks API.
public struct SlackBookmark: Sendable, Hashable, Codable {
    public let channelID: String
    public let id: String
    public let title: String
    public let link: String
    public let lastEditedMs: Int64

    public init(channelID: String, id: String, title: String, link: String, lastEditedMs: Int64) {
        self.channelID = channelID
        self.id = id
        self.title = title
        self.link = link
        self.lastEditedMs = lastEditedMs
    }
}

/// Per-channel bookmarks snapshot used for diffing (added / removed / edited).
public struct SlackChannelBookmarksSnapshot: Sendable, Hashable, Codable {
    public let channelID: String
    public let bookmarks: [SlackBookmark]

    public init(channelID: String, bookmarks: [SlackBookmark]) {
        self.channelID = channelID
        self.bookmarks = bookmarks
    }
}

// MARK: - Reminders

/// One reminder. `dueTs` / `completedTs` are epoch ms; either can be nil for
/// reminders that are not yet due or not yet completed.
public struct SlackReminder: Sendable, Hashable, Codable {
    public let id: String
    public let dueTs: Int64?
    public let completedTs: Int64?

    public init(id: String, dueTs: Int64?, completedTs: Int64?) {
        self.id = id
        self.dueTs = dueTs
        self.completedTs = completedTs
    }
}

public struct SlackRemindersSnapshot: Sendable, Hashable, Codable {
    public let reminders: [SlackReminder]

    public init(reminders: [SlackReminder]) {
        self.reminders = reminders
    }

    public static let empty = SlackRemindersSnapshot(reminders: [])
}

// MARK: - Scheduled messages

/// One scheduled-but-not-yet-sent message. `sent` flips to `true` once Slack's
/// scheduler has dispatched it (diff between ticks emits `sent` event).
public struct SlackScheduledMessage: Sendable, Hashable, Codable {
    public let id: String
    public let channelID: String
    public let scheduledFor: Int64
    public let sent: Bool

    public init(id: String, channelID: String, scheduledFor: Int64, sent: Bool) {
        self.id = id
        self.channelID = channelID
        self.scheduledFor = scheduledFor
        self.sent = sent
    }
}

public struct SlackScheduledMessagesSnapshot: Sendable, Hashable, Codable {
    public let messages: [SlackScheduledMessage]

    public init(messages: [SlackScheduledMessage]) {
        self.messages = messages
    }

    public static let empty = SlackScheduledMessagesSnapshot(messages: [])
}

// MARK: - Stars (saved items)

/// One starred (saved) item. `itemRef` is the canonical "channelID:messageTs"
/// composite or "file:fileID" — message bodies / file contents never captured.
public struct SlackStarItem: Sendable, Hashable, Codable {
    public let itemRef: String
    public let savedAtMs: Int64

    public init(itemRef: String, savedAtMs: Int64) {
        self.itemRef = itemRef
        self.savedAtMs = savedAtMs
    }
}

public struct SlackStarsSnapshot: Sendable, Hashable, Codable {
    public let stars: [SlackStarItem]

    public init(stars: [SlackStarItem]) {
        self.stars = stars
    }

    public static let empty = SlackStarsSnapshot(stars: [])
}

// MARK: - Canvases (cold tier)

/// One canvas. `channelID` is `nil` for free-floating canvases (not channel-bound).
/// `title` is the canvas's own title field (structured metadata), not body content.
public struct SlackCanvas: Sendable, Hashable, Codable {
    public let channelID: String?
    public let canvasID: String
    public let title: String
    public let lastEditedMs: Int64

    public init(channelID: String?, canvasID: String, title: String, lastEditedMs: Int64) {
        self.channelID = channelID
        self.canvasID = canvasID
        self.title = title
        self.lastEditedMs = lastEditedMs
    }
}

public struct SlackCanvasesSnapshot: Sendable, Hashable, Codable {
    public let canvases: [SlackCanvas]

    public init(canvases: [SlackCanvas]) {
        self.canvases = canvases
    }

    public static let empty = SlackCanvasesSnapshot(canvases: [])
}

// MARK: - Custom emoji (cold tier)

/// Workspace custom emoji catalog snapshot — names only. ADR-010: emoji image
/// content (URLs / bytes) is never captured; only the name set is retained for
/// added/removed diff emission.
public struct SlackEmojiSnapshot: Sendable, Hashable, Codable {
    public let emojiNames: Set<String>

    public init(emojiNames: Set<String>) {
        self.emojiNames = emojiNames
    }

    public static let empty = SlackEmojiSnapshot(emojiNames: [])
}

// MARK: - Usergroups (cold tier)

/// One usergroup with its member set. `userIDs` is captured as-is for membership
/// diff; downstream Share Controls / anonymization apply at the relay boundary.
public struct SlackUsergroup: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let userIDs: Set<String>

    public init(id: String, name: String, userIDs: Set<String>) {
        self.id = id
        self.name = name
        self.userIDs = userIDs
    }
}

public struct SlackUsergroupsSnapshot: Sendable, Hashable, Codable {
    public let groups: [SlackUsergroup]

    public init(groups: [SlackUsergroup]) {
        self.groups = groups
    }

    public static let empty = SlackUsergroupsSnapshot(groups: [])
}

// MARK: - Channels info (cold tier — archived/renamed detection)

/// One channel's identity snapshot — used to detect rename / archive transitions
/// across cold ticks. Name and archived flag are structured channel state, not
/// message bodies.
public struct SlackChannelInfo: Sendable, Hashable, Codable {
    public let channelID: String
    public let name: String
    public let isArchived: Bool

    public init(channelID: String, name: String, isArchived: Bool) {
        self.channelID = channelID
        self.name = name
        self.isArchived = isArchived
    }
}

public struct SlackChannelsInfoSnapshot: Sendable, Hashable, Codable {
    public let channels: [SlackChannelInfo]

    public init(channels: [SlackChannelInfo]) {
        self.channels = channels
    }

    public static let empty = SlackChannelsInfoSnapshot(channels: [])
}

// MARK: - Warm / cold batch aggregates

/// Aggregate result of one warm-tier (15m) tick. Each field corresponds to one
/// endpoint group; per-endpoint failure tolerance lives in the implementation
/// (any single group may be `.empty` while the rest succeed).
public struct SlackWarmBatch: Sendable, Hashable {
    public let memberChannelsTopList: SlackMemberChannelsTopList
    public let reactions: SlackReactionsBatch
    public let pinsPerChannel: [SlackChannelPinsSnapshot]
    public let bookmarksPerChannel: [SlackChannelBookmarksSnapshot]
    public let reminders: SlackRemindersSnapshot
    public let scheduledMessages: SlackScheduledMessagesSnapshot
    public let stars: SlackStarsSnapshot

    public init(
        memberChannelsTopList: SlackMemberChannelsTopList,
        reactions: SlackReactionsBatch,
        pinsPerChannel: [SlackChannelPinsSnapshot],
        bookmarksPerChannel: [SlackChannelBookmarksSnapshot],
        reminders: SlackRemindersSnapshot,
        scheduledMessages: SlackScheduledMessagesSnapshot,
        stars: SlackStarsSnapshot
    ) {
        self.memberChannelsTopList = memberChannelsTopList
        self.reactions = reactions
        self.pinsPerChannel = pinsPerChannel
        self.bookmarksPerChannel = bookmarksPerChannel
        self.reminders = reminders
        self.scheduledMessages = scheduledMessages
        self.stars = stars
    }

    public static let empty = SlackWarmBatch(
        memberChannelsTopList: .empty,
        reactions: .empty,
        pinsPerChannel: [],
        bookmarksPerChannel: [],
        reminders: .empty,
        scheduledMessages: .empty,
        stars: .empty
    )
}

/// Prior-tick persisted warm-state fed back into `fetchWarmState` so day-2+
/// ticks can rank per-channel fan-out off the stable previous snapshot (rather
/// than the volatile just-fetched member set) and diff pins/bookmarks/reminders/
/// scheduled/stars against last tick. Mirrors `SlackWarmBatch` minus `reactions`
/// (reactions carry no prior state — they are always fetched fresh).
///
/// `memberChannels` is `nil` on bootstrap (tick #1): with no prior snapshot the
/// provider falls back to the just-fetched member set for fan-out targeting.
public struct SlackWarmStatePriorSnapshots: Sendable, Hashable {
    public let memberChannels: SlackMemberChannelsTopList?
    public let pinsPerChannel: [SlackChannelPinsSnapshot]
    public let bookmarksPerChannel: [SlackChannelBookmarksSnapshot]
    public let reminders: SlackRemindersSnapshot
    public let scheduledMessages: SlackScheduledMessagesSnapshot
    public let stars: SlackStarsSnapshot

    public init(
        memberChannels: SlackMemberChannelsTopList?,
        pinsPerChannel: [SlackChannelPinsSnapshot],
        bookmarksPerChannel: [SlackChannelBookmarksSnapshot],
        reminders: SlackRemindersSnapshot,
        scheduledMessages: SlackScheduledMessagesSnapshot,
        stars: SlackStarsSnapshot
    ) {
        self.memberChannels = memberChannels
        self.pinsPerChannel = pinsPerChannel
        self.bookmarksPerChannel = bookmarksPerChannel
        self.reminders = reminders
        self.scheduledMessages = scheduledMessages
        self.stars = stars
    }

    /// Bootstrap prior — `memberChannels == nil` switches fan-out to the
    /// just-fetched member set; all diff baselines start empty.
    public static let empty = SlackWarmStatePriorSnapshots(
        memberChannels: nil,
        pinsPerChannel: [],
        bookmarksPerChannel: [],
        reminders: .empty,
        scheduledMessages: .empty,
        stars: .empty
    )
}

/// Aggregate result of one cold-tier (4am local daily) tick.
public struct SlackColdBatch: Sendable, Hashable {
    public let canvases: SlackCanvasesSnapshot
    public let emoji: SlackEmojiSnapshot
    public let usergroups: SlackUsergroupsSnapshot
    public let channelsInfo: SlackChannelsInfoSnapshot

    public init(
        canvases: SlackCanvasesSnapshot,
        emoji: SlackEmojiSnapshot,
        usergroups: SlackUsergroupsSnapshot,
        channelsInfo: SlackChannelsInfoSnapshot
    ) {
        self.canvases = canvases
        self.emoji = emoji
        self.usergroups = usergroups
        self.channelsInfo = channelsInfo
    }

    public static let empty = SlackColdBatch(
        canvases: .empty,
        emoji: .empty,
        usergroups: .empty,
        channelsInfo: .empty
    )
}
