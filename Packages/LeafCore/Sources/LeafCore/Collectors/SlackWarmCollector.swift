//
//  SlackWarmCollector.swift
//  LeafCore
//
//  Phase Track-3 D3 Task 12 — Slack warm-tier (15m) collector actor body.
//  Mirrors GitHubWarmCollector / LinearWarmCollector shape — actor + start/stop
//  loop + performTick + atomic write through `Database.writeEventsOffsetsAndSnapshots`.
//
//  Seven endpoint groups, 13 event_kinds:
//   1. user.conversations → slack_channel_joined / _left (top-10 latestTs rank)
//   2. reactions.list (self-authored) → slack_reaction_added (positive deltas only,
//      bucketed emoji per ADR-010 §6 — no raw emoji name)
//   3. pins.list (per top-10 channel) → slack_pin_added / _removed (id-set diff)
//   4. bookmarks.list (per top-10 channel) → slack_bookmark_added / _removed (id diff,
//      title routes through `body` for FTS pickup — body_kind `slack_bookmark_title`)
//   5. reminders.list → slack_reminder_created / _completed (id diff + completedTs
//      transition)
//   6. chat.scheduledMessages.list → slack_message_scheduled / _sent_scheduled
//      (id diff + sent transition; disappeared rows treated as sent)
//   7. stars.list → slack_item_saved / _unsaved (itemRef set-diff)
//
//  Bootstrap discipline: first tick with no prior snapshot per slot writes
//  the snapshot but emits zero diff events. Subsequent ticks produce the
//  normal added/removed/transition stream.
//
//  Scope gating: collector consults `SlackScopesChecking` BEFORE emitting
//  events for each endpoint group. Provider implementation honours scopes
//  too (returns empty arrays for missing scopes) but collector double-guards
//  emission so that out-of-spec provider stubs cannot leak events for
//  missing-scope endpoints.
//
//  Atomic write: events + offset + snapshots through a single
//  `Database.writeEventsOffsetsAndSnapshots` transaction. Provider failure
//  → no write → cursor stays at prior tick (retry next tick).
//
//  Privacy (ADR-010 §6): pinned-message bodies / message text / reminder
//  text / scheduled-message text / file content — never captured. Bookmark
//  titles are user-named structured resources (not message bodies) and are
//  allowed by ADR-010 §6.
//

import Foundation
import os

public actor SlackWarmCollector {
    /// Cap on member-channels persisted to snapshot + fanned out per-channel.
    public static let topN = 10

    private let database: Database
    private let provider: any SlackAPIProvider
    private let tokenRefresher: SlackTokenRefresher
    private let scopes: any SlackScopesChecking
    private let workspaceIDProvider: @Sendable () -> String?
    private let userIDProvider: @Sendable () -> String?
    private let clock: @Sendable () -> Date
    private let logger: Logger

    public init(
        database: Database,
        provider: any SlackAPIProvider,
        tokenRefresher: SlackTokenRefresher,
        scopes: any SlackScopesChecking,
        workspaceIDProvider: @escaping @Sendable () -> String?,
        userIDProvider: @escaping @Sendable () -> String?,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.tokenRefresher = tokenRefresher
        self.scopes = scopes
        self.workspaceIDProvider = workspaceIDProvider
        self.userIDProvider = userIDProvider
        self.clock = clock
        self.logger = logger
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
        public init(skipped: Bool, eventsEmitted: Int) {
            self.skipped = skipped
            self.eventsEmitted = eventsEmitted
        }
    }

    @discardableResult
    public func performTick(now: Date? = nil) async -> TickResult {
        let tickNow = now ?? clock()
        let nowMs = Int64(tickNow.timeIntervalSince1970 * 1000)

        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .slack)
        } catch {
            logger.error("warm readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await tokenRefresher.refreshIfNeeded(now: tickNow)
        } catch SlackTokenRefresherError.refreshDenied(let msg) {
            logger.warning("warm refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("warm refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        // 3. Resolve workspaceID + userID. Prefer integration record (single
        // source of truth in production) but fall back to closures supplied
        // at construction time (tests / Agent wiring).
        let teamID: String
        let userID: String
        let parts = refreshed.workspaceID.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            teamID = String(parts[0])
            userID = String(parts[1])
        } else if let w = workspaceIDProvider(), let u = userIDProvider() {
            teamID = w
            userID = u
        } else {
            logger.error("malformed workspaceID '\(refreshed.workspaceID, privacy: .public)' — expected '<team>:<user>'")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        let sourceID = "slack:warm:\(teamID):\(userID)"

        // 4. Read cursor + prior snapshots.
        let cursor = (try? database.readOffset(
            collectorID: CollectorID.slackWarmPolling,
            sourceID: sourceID
        ))?.lastModifiedMs

        let priorMemberChannels: SlackMemberChannelsTopList? =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackMemberChannels)
        let priorPins: [SlackChannelPinsSnapshot] =
            readSnapshotArray(kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel)
        let priorPinsRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel)
        let priorBookmarks: [SlackChannelBookmarksSnapshot] =
            readSnapshotArray(kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel)
        let priorBookmarksRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel)
        let priorReminders: SlackRemindersSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackReminders) ?? .empty
        let priorRemindersRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackReminders)
        let priorScheduled: SlackScheduledMessagesSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackScheduledMessages) ?? .empty
        let priorScheduledRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackScheduledMessages)
        let priorStars: SlackStarsSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackStars) ?? .empty
        let priorStarsRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackStars)

        // 5. Fetch warm state from provider. Per-endpoint failure tolerance
        // lives inside the provider impl; a top-level throw aborts the tick
        // entirely and leaves the cursor unchanged so the next tick retries.
        let batch: SlackWarmBatch
        do {
            batch = try await provider.fetchWarmState(
                accessToken: refreshed.accessToken,
                userID: userID,
                scopes: scopes,
                priors: SlackWarmStatePriorSnapshots(
                    memberChannels: priorMemberChannels,
                    pinsPerChannel: priorPins,
                    bookmarksPerChannel: priorBookmarks,
                    reminders: priorReminders,
                    scheduledMessages: priorScheduled,
                    stars: priorStars
                ),
                since: cursor,
                now: nowMs
            )
        } catch {
            logger.error("fetchWarmState failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }

        // 6. Diff source = FULL member set from provider (persisted as-is to
        //    `slackMemberChannels`). Top-N fan-out cap for per-channel sub-fans
        //    (pins / bookmarks) is the provider's internal responsibility —
        //    it consumes `priorMemberChannels` for its own ranking.
        //    C3 review fix: persisting the cap caused false-positive join/left
        //    events on rank churn (>10 active channels).
        let fullMemberSet = batch.memberChannelsTopList

        // 7. Build events.
        var events: [RawEvent] = []
        let workspaceID = teamID

        // 7a. Channel joined/left — diff on FULL set, not top-N cap.
        if await scopes.has("channels:read") {
            let diff = Self.userConversationsDiff(prior: priorMemberChannels, current: fullMemberSet)
            for ch in diff.joined {
                events.append(Self.makeChannelJoinedEvent(
                    channel: ch, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for ch in diff.left {
                events.append(Self.makeChannelLeftEvent(
                    channel: ch, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7b. Reactions (provider's `since` cursor filters new reactions —
        // bootstrap discipline lives in provider impl; collector treats each
        // reaction in the batch as a fresh observation).
        if await scopes.has("reactions:read") {
            for r in batch.reactions.reactions {
                events.append(Self.makeReactionAddedEvent(
                    reaction: r, workspaceID: workspaceID, userID: userID
                ))
            }
        }

        // 7c. Pins per channel — bootstrap-per-channel discipline. The diff
        // helper skips channels with no prior row, so first-tick channels emit
        // nothing. Additionally gate emission on the snapshot row's existence
        // to suppress events before the first persisted snapshot.
        if await scopes.has("pins:read"), priorPinsRowPresent {
            let (added, removed) = Self.pinsPerChannelDiff(prior: priorPins, current: batch.pinsPerChannel)
            for entry in added {
                events.append(Self.makePinAddedEvent(
                    channelID: entry.channelID, itemRef: entry.itemRef,
                    workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for entry in removed {
                events.append(Self.makePinRemovedEvent(
                    channelID: entry.channelID, itemRef: entry.itemRef,
                    workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7d. Bookmarks per channel.
        if await scopes.has("bookmarks:read"), priorBookmarksRowPresent {
            let (added, removed) = Self.bookmarksPerChannelDiff(prior: priorBookmarks, current: batch.bookmarksPerChannel)
            for bm in added {
                events.append(Self.makeBookmarkAddedEvent(
                    bookmark: bm, workspaceID: workspaceID, userID: userID
                ))
            }
            for bm in removed {
                events.append(Self.makeBookmarkRemovedEvent(
                    bookmark: bm, workspaceID: workspaceID, userID: userID
                ))
            }
        }

        // 7e. Reminders.
        if await scopes.has("reminders:read"), priorRemindersRowPresent {
            let (created, completed) = Self.remindersDiff(prior: priorReminders, current: batch.reminders)
            for r in created {
                events.append(Self.makeReminderCreatedEvent(
                    reminder: r, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for r in completed {
                events.append(Self.makeReminderCompletedEvent(
                    reminder: r, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7f. Scheduled messages. Slack's `chat.scheduledMessages.list` scope
        // is implicit on `chat:write` for the authoring user — gate on that
        // canonical scope.
        if await scopes.has("chat:write"), priorScheduledRowPresent {
            let (scheduled, sent) = Self.scheduledMessagesDiff(prior: priorScheduled, current: batch.scheduledMessages)
            for m in scheduled {
                events.append(Self.makeMessageScheduledEvent(
                    message: m, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for m in sent {
                events.append(Self.makeMessageSentScheduledEvent(
                    message: m, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7g. Stars (saved items).
        if await scopes.has("stars:read"), priorStarsRowPresent {
            let (saved, unsaved) = Self.starsDiff(prior: priorStars, current: batch.stars)
            for item in saved {
                events.append(Self.makeItemSavedEvent(
                    item: item, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for item in unsaved {
                events.append(Self.makeItemUnsavedEvent(
                    item: item, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 8. Build offset + snapshots.
        let offset = CollectorOffset(
            collectorID: CollectorID.slackWarmPolling,
            sourceID: sourceID,
            byteOffset: 0, inode: nil, size: 0,
            lastModifiedMs: nowMs, updatedMs: nowMs
        )

        let snapshots: [ProviderSnapshot] = [
            // Persist the FULL member set — diff source for join/left + fan-out
            // root for cold tier (cold caps locally via rankTop10ByLatestTs).
            // C3 review fix: previously persisted top-10 cap caused false-
            // positive transitions on rank churn.
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackMemberChannels,
                         encoding: fullMemberSet,
                         nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel,
                         encoding: batch.pinsPerChannel, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel,
                         encoding: batch.bookmarksPerChannel, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackReminders,
                         encoding: batch.reminders, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackScheduledMessages,
                         encoding: batch.scheduledMessages, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackStars,
                         encoding: batch.stars, nowMs: nowMs)
        ]

        // 9. Atomic write.
        do {
            try database.writeEventsOffsetsAndSnapshots(
                events: events, offsets: [offset], snapshots: snapshots
            )
        } catch {
            logger.error("warm persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("slack warm tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    // MARK: - Snapshot helpers

    private func snapshotRowPresent(kind: String) -> Bool {
        do {
            return try database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: "slack", snapshotKind: kind, in: raw
                ) != nil
            }
        } catch {
            return false
        }
    }

    private func readSnapshotArray<T: Decodable>(kind: String) -> [T] {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "slack", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(s.snapshotJSON.utf8))) ?? []
    }

    private func readSnapshotValue<T: Decodable>(kind: String) -> T? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "slack", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.snapshotJSON.utf8))
    }

    private func makeSnapshot<T: Encodable>(kind: String, encoding value: T, nowMs: Int64) -> ProviderSnapshot {
        let json: String
        if let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "{}"
        }
        return ProviderSnapshot(
            provider: "slack", snapshotKind: kind,
            snapshotJSON: json, capturedAtMs: nowMs
        )
    }

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
            "star", "sparkles", "trophy", "champagne"
        ]
        let negative: Set<String> = [
            "-1", "thumbsdown", "cry", "sob", "rage", "angry",
            "x", "no_entry", "no_entry_sign", "warning",
            "disappointed", "confounded", "frowning", "weary"
        ]
        let normalized = emoji
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.reactedAtMs: String(reaction.addedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.userId: userID
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
                Schema.EventPayloadKeys.userId: userID
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
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
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
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
            ]
        )
    }
}
