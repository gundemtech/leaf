//
//  SlackWarmCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — static event builders for warm-tier
//  Slack events (channel join/leave, reactions, pins, bookmarks, reminders,
//  scheduled messages, stars). Pure relocation from SlackWarmCollector.swift.
//

import Foundation

extension SlackWarmCollector {
    // MARK: - Emoji bucketing
    //
    // ADR-010 §6: we don't capture raw emoji names — only a coarse positive /
    // negative / neutral bucket. The lookup is intentionally short (top
    // commonly-used) and falls through to "neutral" for anything else; the
    // bucket is structured metadata, not body content.
    static func bucketEmoji(_ emoji: String) -> String {
        let positive: Set<String> = [
            "+1", "thumbsup", "heart", "tada", "white_check_mark", "ok_hand",
            "rocket", "fire", "100", "raised_hands", "clap", "muscle",
            "smile", "smiley", "grin", "joy", "blush", "wink", "heart_eyes",
            "star", "sparkles", "trophy", "champagne",
        ]
        let negative: Set<String> = [
            "-1", "thumbsdown", "cry", "sob", "rage", "angry",
            "x", "no_entry", "no_entry_sign", "warning",
            "disappointed", "confounded", "frowning", "weary",
        ]
        let normalized =
            emoji
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
        if positive.contains(normalized) { return "positive" }
        if negative.contains(normalized) { return "negative" }
        return "neutral"
    }

    // MARK: - Event builders

    static func makeChannelJoinedEvent(
        channel: SlackMemberChannel, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackChannelJoined.rawValue,
                Schema.EventPayloadKeys.channelId: channel.id,
                Schema.EventPayloadKeys.channelName: channel.name,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeChannelLeftEvent(
        channel: SlackMemberChannel, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackChannelLeft.rawValue,
                Schema.EventPayloadKeys.channelId: channel.id,
                Schema.EventPayloadKeys.channelName: channel.name,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeReactionAddedEvent(
        reaction: SlackReaction, workspaceID: String, userID: String
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(reaction.addedAtMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackReactionAdded.rawValue,
                Schema.EventPayloadKeys.itemRef: reaction.itemRef,
                Schema.EventPayloadKeys.emojiBucket: bucketEmoji(reaction.emoji),
                Schema.EventPayloadKeys.reactionCount: "1",
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.reactedAtMs: String(reaction.addedAtMs),
            ]
        )
    }

    static func makePinAddedEvent(
        channelID: String, itemRef: String,
        workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackPinAdded.rawValue,
                Schema.EventPayloadKeys.channelId: channelID,
                Schema.EventPayloadKeys.itemRef: itemRef,
                Schema.EventPayloadKeys.pinnedAtMs: String(observedAtMs),
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makePinRemovedEvent(
        channelID: String, itemRef: String,
        workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackPinRemoved.rawValue,
                Schema.EventPayloadKeys.channelId: channelID,
                Schema.EventPayloadKeys.itemRef: itemRef,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeBookmarkAddedEvent(
        bookmark: SlackBookmark, workspaceID: String, userID: String
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(bookmark.lastEditedMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackBookmarkAdded.rawValue,
                Schema.EventPayloadKeys.channelId: bookmark.channelID,
                Schema.EventPayloadKeys.bookmarkId: bookmark.id,
                Schema.EventPayloadKeys.bookmarkTitle: bookmark.title,
                Schema.EventPayloadKeys.bookmarkURL: bookmark.link,
                Schema.EventPayloadKeys.lastEditedMs: String(bookmark.lastEditedMs),
                // Mirror title under canonical `body` so EventsFullTextStore can
                // route it to body_kind `slack_bookmark_title` (per ADR-010 §6
                // bookmark titles are user-named structured resources).
                Schema.EventPayloadKeys.body: bookmark.title,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
            ]
        )
    }

    static func makeBookmarkRemovedEvent(
        bookmark: SlackBookmark, workspaceID: String, userID: String
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(bookmark.lastEditedMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackBookmarkRemoved.rawValue,
                Schema.EventPayloadKeys.channelId: bookmark.channelID,
                Schema.EventPayloadKeys.bookmarkId: bookmark.id,
                Schema.EventPayloadKeys.bookmarkTitle: bookmark.title,
                Schema.EventPayloadKeys.bookmarkURL: bookmark.link,
                Schema.EventPayloadKeys.lastEditedMs: String(bookmark.lastEditedMs),
                Schema.EventPayloadKeys.body: bookmark.title,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
            ]
        )
    }

    static func makeReminderCreatedEvent(
        reminder: SlackReminder, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackReminderCreated.rawValue,
            Schema.EventPayloadKeys.reminderId: reminder.id,
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.userId: userID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let due = reminder.dueTs {
            payload[Schema.EventPayloadKeys.dueTs] = String(due)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeReminderCompletedEvent(
        reminder: SlackReminder, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        let completedMs = reminder.completedTs ?? observedAtMs
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(completedMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackReminderCompleted.rawValue,
                Schema.EventPayloadKeys.reminderId: reminder.id,
                Schema.EventPayloadKeys.completedTs: String(completedMs),
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeMessageScheduledEvent(
        message: SlackScheduledMessage, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackMessageScheduled.rawValue,
                Schema.EventPayloadKeys.scheduledMessageId: message.id,
                Schema.EventPayloadKeys.channelId: message.channelID,
                Schema.EventPayloadKeys.scheduledFor: String(message.scheduledFor),
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeMessageSentScheduledEvent(
        message: SlackScheduledMessage, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackMessageSentScheduled.rawValue,
                Schema.EventPayloadKeys.scheduledMessageId: message.id,
                Schema.EventPayloadKeys.channelId: message.channelID,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeItemSavedEvent(
        item: SlackStarItem, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(item.savedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackItemSaved.rawValue,
                Schema.EventPayloadKeys.itemRef: item.itemRef,
                Schema.EventPayloadKeys.savedAtMs: String(item.savedAtMs),
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }

    static func makeItemUnsavedEvent(
        item: SlackStarItem, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": SlackEventKindKey.slackItemUnsaved.rawValue,
                Schema.EventPayloadKeys.itemRef: item.itemRef,
                Schema.EventPayloadKeys.workspaceId: workspaceID,
                Schema.EventPayloadKeys.userId: userID,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ]
        )
    }
}
